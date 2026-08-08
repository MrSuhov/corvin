import Foundation
import AppKit
import ApplicationServices
import Carbon

/// "Punto Switcher" behaviour: re-type the selected text — or, with nothing
/// selected, the word behind the caret — in the other keyboard layout.
///
/// Two paths, tried in order:
///
/// 1. **Accessibility.** Read and write the text directly on the focused
///    element. Nothing is synthesised, the pasteboard is untouched, and it is
///    instant. Works in native Cocoa fields, Safari, Xcode, Notes.
/// 2. **Clipboard.** Synthetic ⌘C / ⌘V with the user's pasteboard snapshotted
///    and restored. Slower and lossier, but it is the only thing that reaches
///    Electron apps before their AX tree comes up, and some web views.
final class LayoutSwitchService {

    private let accessibility: AccessibilityService

    /// Serialises conversions. Both paths involve async waits, and a second tap
    /// arriving mid-flight would race on the pasteboard snapshot.
    private var isConverting = false

    /// How far back the "last word" scan may run. Also bounds the AX text read.
    private static let maxWordLength = 128

    private enum VirtualKey {
        static let c: CGKeyCode = 0x08
        static let v: CGKeyCode = 0x09
        static let leftArrow: CGKeyCode = 0x7B
    }

    init(accessibility: AccessibilityService) {
        self.accessibility = accessibility
    }

    // MARK: - Entry point

    /// Called from the Option-tap hotkey. Must run on the main thread.
    func convertTextAtCursor() {
        guard UserDefaults.standard.bool(forKey: "layoutSwitchEnabled") else { return }

        guard !isConverting else {
            flog("layoutSwitch: ignored, conversion already in flight")
            return
        }

        guard accessibility.hasAccessibilityPermission else {
            flog("layoutSwitch: no accessibility permission")
            return
        }

        // Password fields and terminals with secure input swallow synthetic
        // keystrokes and hide their text; a half-applied edit there is worse
        // than doing nothing.
        guard !accessibility.isSecureInputActive else {
            flog("layoutSwitch: secure input active, skipping")
            return
        }

        isConverting = true
        accessibility.enableManualAccessibility()

        if convertViaAccessibility() {
            isConverting = false
            return
        }

        flog("layoutSwitch: AX path unavailable, falling back to clipboard")
        convertViaClipboard { [weak self] in
            self?.isConverting = false
        }
    }

    // MARK: - Path 1: Accessibility

    /// Returns true when the conversion was fully handled here.
    private func convertViaAccessibility() -> Bool {
        guard let element = accessibility.focusedElement() else {
            flog("layoutSwitch: no focused element")
            return false
        }

        if let selection = accessibility.selectedText(of: element) {
            guard let converted = convertOrNil(selection) else { return true }
            guard accessibility.replaceSelectedText(converted, of: element) else { return false }
            flog("layoutSwitch: AX replaced selection (\(selection.count) chars)")
            applyInputSourceSwitch(for: selection)
            return true
        }

        guard let (chunk, chunkStart) = accessibility.textBeforeCaret(
            of: element,
            maxLength: Self.maxWordLength
        ) else {
            return false
        }

        guard let relativeRange = LayoutMapper.lastWordRange(
            in: chunk,
            caret: chunk.utf16.count,
            maxWordLength: Self.maxWordLength
        ) else {
            flog("layoutSwitch: nothing to convert behind caret")
            return true
        }

        guard let stringRange = Range(
            NSRange(location: relativeRange.lowerBound, length: relativeRange.count),
            in: chunk
        ) else { return false }

        let word = String(chunk[stringRange])
        guard let converted = convertOrNil(word) else { return true }

        let absolute = (chunkStart + relativeRange.lowerBound)..<(chunkStart + relativeRange.upperBound)
        guard accessibility.setSelectedRange(absolute, of: element),
              accessibility.replaceSelectedText(converted, of: element)
        else {
            return false
        }

        flog("layoutSwitch: AX replaced last word '\(word)' -> '\(converted)'")
        applyInputSourceSwitch(for: word)
        return true
    }

    // MARK: - Path 2: Clipboard

    private func convertViaClipboard(completion: @escaping () -> Void) {
        let snapshot = accessibility.snapshotPasteboard()

        let finish = { [weak self] in
            self?.accessibility.restorePasteboard(snapshot)
            completion()
        }

        // Try an existing selection first. If ⌘C leaves the pasteboard
        // untouched there was nothing selected, so grab the previous word.
        copySelection { [weak self] selected in
            guard let self = self else { return finish() }

            if let selected = selected {
                self.pasteConversion(of: selected, then: finish)
                return
            }

            self.accessibility.postKeystroke(
                virtualKey: VirtualKey.leftArrow,
                flags: [.maskShift, .maskAlternate]
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.copySelection { word in
                    guard let word = word else {
                        flog("layoutSwitch: clipboard path found nothing to convert")
                        return finish()
                    }
                    self.pasteConversion(of: word, then: finish)
                }
            }
        }
    }

    private func pasteConversion(of original: String, then completion: @escaping () -> Void) {
        guard let converted = convertOrNil(original) else { return completion() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return completion() }
            self.accessibility.postKeystroke(virtualKey: VirtualKey.v, flags: .maskCommand)
            flog("layoutSwitch: clipboard replaced '\(original)' -> '\(converted)'")

            // Give the target app time to consume the paste before the
            // pasteboard is rewound to the user's own content.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.applyInputSourceSwitch(for: original)
                completion()
            }
        }
    }

    /// Sends ⌘C and waits for the pasteboard to actually change. Returns nil
    /// when nothing was copied, which is how "no selection" is detected.
    private func copySelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        accessibility.postKeystroke(virtualKey: VirtualKey.c, flags: .maskCommand)

        pollPasteboard(changeCountBefore: changeCountBefore, attemptsLeft: 20) { changed in
            guard changed, let text = pasteboard.string(forType: .string), !text.isEmpty else {
                return completion(nil)
            }
            completion(text)
        }
    }

    /// Polls every 20 ms for up to 400 ms. A fixed sleep would either be too
    /// short for a slow app or waste time in a fast one.
    private func pollPasteboard(
        changeCountBefore: Int,
        attemptsLeft: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if NSPasteboard.general.changeCount != changeCountBefore {
            return completion(true)
        }
        guard attemptsLeft > 0 else { return completion(false) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self = self else { return completion(false) }
            self.pollPasteboard(
                changeCountBefore: changeCountBefore,
                attemptsLeft: attemptsLeft - 1,
                completion: completion
            )
        }
    }

    // MARK: - Conversion

    /// Converts `text`, or returns nil when the conversion is a no-op — text made
    /// entirely of digits, spaces or symbols shared by both layouts. Replacing it
    /// would be a pointless edit that still dirties the undo stack.
    private func convertOrNil(_ text: String) -> String? {
        let converted = LayoutMapper.convert(text)
        guard converted != text else {
            flog("layoutSwitch: conversion is a no-op, skipping")
            return nil
        }
        return converted
    }

    // MARK: - Input source

    /// Switches the system input source to match the layout we just converted
    /// *into*, so continued typing stays in the language the user meant.
    private func applyInputSourceSwitch(for originalText: String) {
        guard UserDefaults.standard.bool(forKey: "layoutSwitchChangesInputSource") else { return }

        // enToRu means the original was Latin and we produced Russian.
        let targetLanguage = LayoutMapper.detectDirection(originalText) == .enToRu ? "ru" : "en"
        selectInputSource(language: targetLanguage)
    }

    private func selectInputSource(language: String) {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            flog("layoutSwitch: TISCreateInputSourceList returned nothing")
            return
        }

        let match = sources.first { source in
            guard property(source, kTISPropertyInputSourceCategory) as? String
                    == (kTISCategoryKeyboardInputSource as String),
                  property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true,
                  property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true,
                  let languages = property(source, kTISPropertyInputSourceLanguages) as? [String]
            else { return false }
            return languages.first == language
        }

        guard let match = match else {
            flog("layoutSwitch: no enabled input source for '\(language)'")
            return
        }

        let status = TISSelectInputSource(match)
        flog("layoutSwitch: TISSelectInputSource('\(language)') status=\(status)")
    }

    private func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
