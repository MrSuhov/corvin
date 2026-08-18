import Foundation
import AppKit
import ApplicationServices
import Carbon

/// "Punto Switcher" behaviour: re-type the selected text — or, with nothing
/// selected, the word behind the caret — in the other keyboard layout.
///
/// Every step that changes the document goes through synthetic keystrokes and
/// the pasteboard, never through the Accessibility API. AX *writes* cannot be
/// trusted: in Electron apps `AXUIElementSetAttributeValue` returns `.success`
/// while the edit never reaches the document, and the AX state left behind is
/// indistinguishable from a successful edit — so the failure can't be caught
/// after the fact either. ⌘C / ⌘V behave the same everywhere, and are what the
/// dictation path already relies on.
///
/// AX *reads*, on the other hand, are used freely — for whether a selection
/// exists right now (editors copy the whole current line when ⌘C runs with an
/// empty selection, so without that hint a caret resting in a line looks
/// exactly like a selected line), and for the text itself where the element
/// offers it.
///
/// The flow:
///   1. get the target text selected — it already is, or the token behind the
///      caret is selected with Shift+←,
///   2. work out what it says: from the AX text when the selection can be
///      confirmed to match what was aimed at, otherwise with ⌘C,
///   3. convert, put it on the pasteboard, ⌘V, restore the pasteboard.
final class LayoutSwitchService {

    private let accessibility: AccessibilityService

    /// Serialises conversions. The flow involves several async waits, and a
    /// second tap arriving mid-flight would race on the pasteboard snapshot.
    private var isConverting = false

    /// Extra pause after Option is seen released, giving the frontmost app time
    /// to process the key-up before it receives a synthetic ⌘C.
    private static let modifierSettleDelay: TimeInterval = 0.05

    /// Pause after a selection-changing keystroke before acting on the result.
    private static let selectionSettleDelay: TimeInterval = 0.05

    /// Pause after ⌘V before the pasteboard is rewound to the user's content.
    private static let pasteSettleDelay: TimeInterval = 0.25

    /// Ceiling on the run of characters `selectPrecedingToken` will walk back
    /// over, so a paragraph with no spaces can't turn into hundreds of
    /// synthetic keystrokes.
    private static let maxTokenLength = 64

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
        flog("layoutSwitch: begin, app=\(accessibility.frontmostBundleIdentifier ?? "unknown")")

        let snapshot = accessibility.snapshotPasteboard()
        let finish: () -> Void = { [weak self] in
            self?.accessibility.restorePasteboard(snapshot)
            self?.isConverting = false
        }

        afterOptionReleased { [weak self] in
            guard let self = self else { return finish() }
            self.selectTarget { target in
                self.convert(target, then: finish)
            }
        }
    }

    // MARK: - Step 1: get the target text selected

    private enum SelectionState {
        case hasSelection
        case caretOnly
        case unknown
    }

    /// What the ⌘V is about to replace.
    private enum Target {
        /// Selected, and its text is already in hand — no ⌘C needed.
        case known(String)
        /// Selected, but only the app knows what it says; read it with ⌘C.
        case opaque
        /// Nothing to convert.
        case nothing
    }

    /// Leaves the app with the text to convert selected, so the ⌘V that follows
    /// replaces it instead of inserting beside it.
    private func selectTarget(completion: @escaping (Target) -> Void) {
        switch selectionStateFromAccessibility() {
        case .hasSelection:
            flog("layoutSwitch: AX reports an existing selection")
            completion(.opaque)

        case .caretOnly:
            flog("layoutSwitch: AX reports a caret with no selection, taking the preceding token")
            selectPrecedingToken(then: completion)

        case .unknown:
            // No usable AX. Probe with ⌘C: if the pasteboard doesn't move there
            // was nothing selected. A result containing a newline is the
            // copy-the-current-line behaviour editors fall back to, which also
            // means there was no selection.
            flog("layoutSwitch: AX unavailable, probing with ⌘C")
            copySelection(label: "probe", attempts: 1) { [weak self] text in
                guard let self = self else { return completion(.nothing) }
                // The probe already read the selection; a second ⌘C would only
                // be another chance to fail.
                if let text = text, !text.contains(where: \.isNewline) {
                    completion(.known(text))
                    return
                }
                if text != nil {
                    flog("layoutSwitch: probe returned a whole line, treating as no selection")
                }
                self.selectPrecedingToken(then: completion)
            }
        }
    }

    private func selectionStateFromAccessibility() -> SelectionState {
        accessibility.enableManualAccessibility()

        guard let element = accessibility.focusedElement() else { return .unknown }
        let role = accessibility.role(of: element) ?? "unknown"

        if accessibility.selectedText(of: element) != nil {
            return .hasSelection
        }

        // Tell "a text element with a caret" apart from "not a text element at
        // all" — only the former justifies grabbing the previous word.
        guard accessibility.selectedRange(of: element) != nil else {
            flog("layoutSwitch: focused element exposes no selection range (role=\(role))")
            return .unknown
        }

        return .caretOnly
    }

    /// Selects the token behind the caret, together with any spaces the caret
    /// is resting after.
    ///
    /// Not Shift+Option+←, which selects by *word*: macOS word motion stops at
    /// punctuation, so `'nj` selects only `nj` and `§rt` only `rt`, leaving the
    /// leading character behind untranslated — and a token that is nothing but
    /// punctuation selects nothing at all. Punto-style conversion works on the
    /// whole space-delimited token, punctuation included, so the boundary is
    /// computed from the text itself and walked with plain Shift+←.
    ///
    /// Falls back to word motion when AX won't hand over the text.
    private func selectPrecedingToken(then completion: @escaping (Target) -> Void) {
        guard let plan = tokenSelectionPlan() else {
            flog("layoutSwitch: AX exposes no text, falling back to word-motion selection")
            accessibility.postKeystroke(
                virtualKey: VirtualKey.leftArrow,
                flags: [.maskShift, .maskAlternate]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionSettleDelay) {
                completion(.opaque)
            }
            return
        }

        guard plan.length > 0 else {
            flog("layoutSwitch: caret is at a whitespace boundary, nothing to convert")
            return completion(.nothing)
        }

        flog("layoutSwitch: selecting \(plan.length) chars back to the token boundary")
        for _ in 0..<plan.length {
            accessibility.postKeystroke(virtualKey: VirtualKey.leftArrow, flags: .maskShift)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay(afterKeystrokes: plan.length)) {
            [weak self] in
            guard let self = self else { return completion(.nothing) }
            completion(self.verifiedTarget(for: plan))
        }
    }

    /// Confirms the arrow keys landed on exactly the range they aimed at.
    ///
    /// When they did, the text AX handed over while measuring the token is
    /// authoritative and the ⌘C can be skipped entirely — which is the point.
    /// That ⌘C is the step that intermittently comes back empty right after a
    /// burst of synthetic arrow keys, leaving the word selected but unchanged
    /// until the user taps again. Re-reading the range costs one AX call and
    /// removes the whole round trip through the app and the pasteboard.
    private func verifiedTarget(for plan: TokenSelectionPlan) -> Target {
        guard let element = accessibility.focusedElement(),
              let range = accessibility.selectedRange(of: element),
              range.location == plan.caret - plan.length,
              range.length == plan.length
        else {
            flog("layoutSwitch: selection didn't land where planned, falling back to ⌘C")
            return .opaque
        }
        return .known(plan.token)
    }

    /// A burst of arrow keys takes the target app proportionally longer to work
    /// through than a single one, so the wait grows with the count.
    private func settleDelay(afterKeystrokes count: Int) -> TimeInterval {
        min(Self.selectionSettleDelay + 0.004 * Double(count), 0.25)
    }

    private struct TokenSelectionPlan {
        /// Caret offset the selection starts from, in UTF-16 units.
        let caret: Int
        /// How many units to select back from it.
        let length: Int
        /// What those units say.
        let token: String
    }

    /// What to select behind the caret, or nil when the focused element won't
    /// say. A zero length means there is nothing to convert.
    ///
    /// Measured in UTF-16 units because that is what `kAXSelectedTextRange`
    /// speaks; for the Latin and Cyrillic this feature deals in, one unit is one
    /// press of ←. A surrogate pair ends the token rather than risking a
    /// half-character selection.
    private func tokenSelectionPlan() -> TokenSelectionPlan? {
        guard let element = accessibility.focusedElement(),
              let range = accessibility.selectedRange(of: element),
              let text = accessibility.value(of: element),
              let found = Self.precedingToken(in: text, caret: range.location)
        else { return nil }

        return TokenSelectionPlan(caret: range.location, length: found.length, token: found.token)
    }

    static func precedingToken(in text: String, caret: Int) -> (length: Int, token: String)? {
        guard let length = precedingTokenLength(in: text, caret: caret) else { return nil }
        let units = Array(text.utf16)
        let start = caret - length
        guard start >= 0, caret <= units.count else { return nil }
        return (length, String(decoding: units[start..<caret], as: UTF16.self))
    }

    static func precedingTokenLength(in text: String, caret: Int) -> Int? {
        let units = Array(text.utf16)
        guard caret >= 0, caret <= units.count else { return nil }

        func scalar(at index: Int) -> Unicode.Scalar? { Unicode.Scalar(units[index]) }

        var index = caret - 1

        // The caret usually sits just after the space that finished the word,
        // so spaces can't end the search — they're stepped over and taken into
        // the selection. Keeping them in it is what holds the caret still:
        // a space converts to itself, so the pasted text is the same length and
        // ends in the same place. Newlines are not crossed; the token on the
        // line above is not what the user meant to convert.
        var trailingSpaces = 0
        while index >= 0, trailingSpaces < maxTokenLength,
              let s = scalar(at: index), CharacterSet.whitespaces.contains(s) {
            trailingSpaces += 1
            index -= 1
        }

        var token = 0
        while index >= 0, token < maxTokenLength,
              let s = scalar(at: index), !CharacterSet.whitespacesAndNewlines.contains(s) {
            token += 1
            index -= 1
        }

        return token > 0 ? token + trailingSpaces : 0
    }

    // MARK: - Steps 2 and 3: read, convert, paste

    private func convert(_ target: Target, then completion: @escaping () -> Void) {
        switch target {
        case .nothing:
            completion()

        case .known(let original):
            replaceSelection(with: original, then: completion)

        case .opaque:
            copySelection(label: "target") { [weak self] text in
                guard let self = self else { return completion() }
                guard let original = text else {
                    flog("layoutSwitch: nothing selected to convert")
                    return completion()
                }
                self.replaceSelection(with: original, then: completion)
            }
        }
    }

    private func replaceSelection(with original: String, then completion: @escaping () -> Void) {
        let converted = LayoutMapper.convert(original)
        guard converted != original else {
            // Digits, spaces, symbols shared by both layouts: replacing them
            // would be a pointless edit that still dirties the undo stack.
            flog("layoutSwitch: conversion is a no-op, skipping")
            return completion()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionSettleDelay) {
            self.accessibility.postKeystroke(virtualKey: VirtualKey.v, flags: .maskCommand)
            flog("layoutSwitch: replaced '\(original)' -> '\(converted)'")

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteSettleDelay) {
                self.applyInputSourceSwitch(for: original)
                completion()
            }
        }
    }

    /// Sends ⌘C and waits for the pasteboard to actually change. Returns nil
    /// when nothing was copied.
    ///
    /// Retried once by default: a Copy posted moments after other synthetic
    /// keystrokes sometimes lands with nothing to show for it, and a second one
    /// against the same selection goes through.
    private func copySelection(label: String, attempts: Int = 2, completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        accessibility.postKeystroke(virtualKey: VirtualKey.c, flags: .maskCommand)

        pollPasteboard(changeCountBefore: changeCountBefore, attemptsLeft: 20) { [weak self] changed in
            if changed, let text = pasteboard.string(forType: .string), !text.isEmpty {
                flog("layoutSwitch: ⌘C for \(label) got \(text.count) chars")
                return completion(text)
            }
            guard let self = self, attempts > 1 else {
                flog("layoutSwitch: ⌘C for \(label) produced no pasteboard change")
                return completion(nil)
            }
            flog("layoutSwitch: ⌘C for \(label) produced no pasteboard change, retrying")
            self.copySelection(label: label, attempts: attempts - 1, completion: completion)
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

    // MARK: - Modifier timing

    /// Runs `work` once the Option key the user just tapped is no longer part of
    /// the modifier state.
    ///
    /// The hotkey fires on Option's key-up, and that event is still travelling
    /// through the window server when the handler runs. A synthetic ⌘C posted
    /// inside that window can reach the app as ⌥⌘C, which is not Copy — while
    /// Shift+Option+← survives the stray Option unnoticed. That asymmetry is
    /// exactly the "the word gets selected but nothing else happens" symptom.
    private func afterOptionReleased(_ work: @escaping () -> Void) {
        func poll(_ attemptsLeft: Int) {
            let held = CGEventSource.flagsState(.combinedSessionState)
            guard held.contains(.maskAlternate), attemptsLeft > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierSettleDelay, execute: work)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll(attemptsLeft - 1) }
        }
        poll(20)
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
