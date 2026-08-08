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
///    Electron apps and some web views.
///
/// The AX path is never trusted on its word: `AXUIElementSetAttributeValue` can
/// return `.success` and still change nothing. Electron apps expose a hidden
/// textarea for screen readers that reads back correctly and accepts writes, but
/// never feeds them into the document model — so a write is confirmed by reading
/// the element again, and an app that fails the check is remembered and served
/// by the clipboard path from then on.
final class LayoutSwitchService {

    private let accessibility: AccessibilityService

    /// Serialises conversions. Both paths involve async waits, and a second tap
    /// arriving mid-flight would race on the pasteboard snapshot.
    private var isConverting = false

    /// Bundle IDs observed to accept an AX text write and then discard it.
    /// Learned at runtime rather than hardcoded, and deliberately not persisted:
    /// a restart re-tests the app, so a bad reading never becomes permanent.
    private var appsDiscardingAXWrites = Set<String>()

    /// How far back the "last word" scan may run. Also bounds the AX text read.
    private static let maxWordLength = 128

    /// Grace period before a write that looks ignored is declared ignored. A
    /// renderer that applies the change asynchronously would otherwise be
    /// misdiagnosed — and running the clipboard path on top of a write that did
    /// land would convert the text a second time, silently undoing it.
    private static let writeVerifyDelay: TimeInterval = 0.05

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

        let bundleID = accessibility.frontmostBundleIdentifier
        flog("layoutSwitch: begin, app=\(bundleID ?? "unknown")")

        let finish: () -> Void = { [weak self] in self?.isConverting = false }

        if let bundleID = bundleID, appsDiscardingAXWrites.contains(bundleID) {
            flog("layoutSwitch: \(bundleID) is known to discard AX writes, using clipboard directly")
            convertViaClipboard(then: finish)
            return
        }

        accessibility.enableManualAccessibility()

        attemptAccessibilityPath(bundleID: bundleID) { [weak self] handled in
            guard let self = self else { return finish() }
            if handled {
                finish()
            } else {
                flog("layoutSwitch: AX path unavailable, falling back to clipboard")
                self.convertViaClipboard(then: finish)
            }
        }
    }

    // MARK: - Path 1: Accessibility

    /// Calls back with true when the conversion was fully handled here.
    private func attemptAccessibilityPath(bundleID: String?, completion: @escaping (Bool) -> Void) {
        guard let element = accessibility.focusedElement() else {
            flog("layoutSwitch: no focused element")
            return completion(false)
        }

        let role = accessibility.role(of: element) ?? "unknown"

        if let selection = accessibility.selectedText(of: element) {
            guard let converted = convertOrNil(selection) else { return completion(true) }
            guard accessibility.replaceSelectedText(converted, of: element) else { return completion(false) }

            confirmWrite(of: selection, on: element, bundleID: bundleID, role: role) { landed in
                if landed {
                    flog("layoutSwitch: AX replaced selection (\(selection.count) chars, role=\(role))")
                    self.applyInputSourceSwitch(for: selection)
                }
                completion(landed)
            }
            return
        }

        guard let (chunk, chunkStart) = accessibility.textBeforeCaret(
            of: element,
            maxLength: Self.maxWordLength
        ) else {
            flog("layoutSwitch: element exposes no text before caret (role=\(role))")
            return completion(false)
        }

        guard let relativeRange = LayoutMapper.lastWordRange(
            in: chunk,
            caret: chunk.utf16.count,
            maxWordLength: Self.maxWordLength
        ) else {
            flog("layoutSwitch: nothing to convert behind caret")
            return completion(true)
        }

        guard let stringRange = Range(
            NSRange(location: relativeRange.lowerBound, length: relativeRange.count),
            in: chunk
        ) else { return completion(false) }

        let word = String(chunk[stringRange])
        guard let converted = convertOrNil(word) else { return completion(true) }

        let absolute = (chunkStart + relativeRange.lowerBound)..<(chunkStart + relativeRange.upperBound)
        guard accessibility.setSelectedRange(absolute, of: element),
              accessibility.replaceSelectedText(converted, of: element)
        else {
            return completion(false)
        }

        confirmWrite(of: word, on: element, bundleID: bundleID, role: role) { landed in
            if landed {
                flog("layoutSwitch: AX replaced last word '\(word)' -> '\(converted)' (role=\(role))")
                self.applyInputSourceSwitch(for: word)
            }
            completion(landed)
        }
    }

    /// Decides whether an AX write actually reached the document.
    ///
    /// The tell is the element still reporting the original text as selected: a
    /// real edit either collapses the selection or leaves the converted text in
    /// it, and `convertOrNil` guarantees converted != original.
    private func confirmWrite(
        of original: String,
        on element: AXUIElement,
        bundleID: String?,
        role: String,
        completion: @escaping (Bool) -> Void
    ) {
        if accessibility.selectedText(of: element) != original {
            return completion(true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeVerifyDelay) { [weak self] in
            guard let self = self else { return completion(false) }

            if self.accessibility.selectedText(of: element) != original {
                return completion(true)
            }

            flog("layoutSwitch: AX write reported success but was discarded by \(bundleID ?? "unknown") (role=\(role))")
            if let bundleID = bundleID {
                self.appsDiscardingAXWrites.insert(bundleID)
            }
            completion(false)
        }
    }

    // MARK: - Path 2: Clipboard

    private func convertViaClipboard(then completion: @escaping () -> Void) {
        let snapshot = accessibility.snapshotPasteboard()

        let finish = { [weak self] in
            self?.accessibility.restorePasteboard(snapshot)
            completion()
        }

        // Try an existing selection first. If ⌘C leaves the pasteboard
        // untouched there was nothing selected, so grab the previous word.
        copySelection { [weak self] selected in
            guard let self = self else { return finish() }

            if let selected = selected, !selected.contains(where: \.isNewline) {
                self.pasteConversion(of: selected, then: finish)
                return
            }

            if selected != nil {
                // Editors copy the whole current line when ⌘C runs with an empty
                // selection. Converting that and pasting it back at a caret would
                // duplicate a mangled line, so treat it as "no selection".
                flog("layoutSwitch: ⌘C returned a full line, treating as no selection")
            }

            self.convertWordViaClipboard(then: finish)
        }
    }

    private func convertWordViaClipboard(then completion: @escaping () -> Void) {
        accessibility.postKeystroke(
            virtualKey: VirtualKey.leftArrow,
            flags: [.maskShift, .maskAlternate]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return completion() }
            self.copySelection { word in
                guard let word = word, !word.contains(where: \.isNewline) else {
                    flog("layoutSwitch: clipboard path found nothing to convert")
                    return completion()
                }
                self.pasteConversion(of: word, then: completion)
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
