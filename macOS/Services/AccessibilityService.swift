import Foundation
import AppKit
import ApplicationServices
import Carbon

class AccessibilityService {
    /// Apps we've already asked to expose their AX tree (see `enableManualAccessibility`).
    private var manualAccessibilityPIDs = Set<pid_t>()

    /// Cap on how long an AX round-trip to another process may take. Every call
    /// here runs on the main thread from a hotkey handler, so a hung target app
    /// must not freeze Corvin.
    private static let axMessagingTimeout: Float = 0.5

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// True while any app has Secure Event Input on (password fields, some
    /// terminals). Synthetic keystrokes are swallowed and AX returns nothing, so
    /// callers must bail out instead of half-completing an edit.
    var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func insertText(_ text: String) {
        flog("insertText: '\(text.prefix(50))' (\(text.count) chars), accessibility=\(hasAccessibilityPermission)")
        pasteViaClipboard(text)
    }

    private func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        let setOk = pasteboard.setString(text, forType: .string)
        flog("pasteViaClipboard: clipboard set=\(setOk), changeCount=\(pasteboard.changeCount)")

        // Small delay to ensure pasteboard is ready before simulating paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Simulate Cmd+V via CGEvent
            let source = CGEventSource(stateID: .hidSystemState)

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                flog("pasteViaClipboard: FAILED to create CGEvent for Cmd+V")
                return
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
            flog("pasteViaClipboard: Cmd+V posted via CGEvent")

            // Restore previous clipboard after paste completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let old = oldContents, pasteboard.changeCount == oldChangeCount + 1 {
                    pasteboard.clearContents()
                    pasteboard.setString(old, forType: .string)
                    flog("pasteViaClipboard: clipboard restored")
                } else {
                    flog("pasteViaClipboard: clipboard not restored (changeCount mismatch or no old contents)")
                }
            }
        }
    }

    // MARK: - Focused text element (Accessibility API)

    /// The system-wide focused UI element, or nil when nothing focusable has focus.
    func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.axMessagingTimeout)

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
        return element
    }

    /// Asks the frontmost app to build an AX tree.
    ///
    /// Chromium and Electron ship with accessibility off and only turn it on when
    /// a client sets `AXManualAccessibility` — without this, `focusedElement()`
    /// returns the window with no text attributes in VS Code, Slack, Chrome, etc.
    /// The tree is built asynchronously, so the very first attempt in such an app
    /// still falls back to the clipboard path; later ones use AX.
    func enableManualAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard !manualAccessibilityPIDs.contains(pid) else { return }
        manualAccessibilityPIDs.insert(pid)

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        flog("enableManualAccessibility: requested for \(app.bundleIdentifier ?? "?") pid=\(pid)")
    }

    /// Currently selected text in `element`, or nil when the element exposes no
    /// selection. An empty selection reads back as nil, not "".
    func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Up to `maxLength` UTF-16 units of text sitting immediately before the
    /// caret, plus the absolute offset where that chunk begins.
    ///
    /// Deliberately does not read `kAXValue` first: in a large document that
    /// copies the whole text across the process boundary on every hotkey press.
    /// The parameterized `kAXStringForRange` attribute fetches only the tail;
    /// `kAXValue` is the fallback for elements that don't implement it.
    ///
    /// Returns nil when the caret is at offset 0, when a selection exists (that
    /// case is handled by `selectedText`), or when the element isn't text.
    func textBeforeCaret(of element: AXUIElement, maxLength: Int) -> (chunk: String, chunkStart: Int)? {
        guard let selection = selectedRange(of: element), selection.length == 0 else { return nil }
        let caret = selection.location
        guard caret > 0 else { return nil }

        let start = max(0, caret - maxLength)
        var cfRange = CFRange(location: start, length: caret - start)

        if let axRange = AXValueCreate(.cfRange, &cfRange) {
            var result: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                axRange,
                &result
            )
            if err == .success, let chunk = result as? String, !chunk.isEmpty {
                // Derive the start from what we actually got back rather than
                // what we asked for, so a short read can't shift the offsets.
                return (chunk, caret - chunk.utf16.count)
            }
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String,
              caret <= text.utf16.count,
              let range = Range(NSRange(location: start, length: caret - start), in: text)
        else { return nil }

        return (String(text[range]), start)
    }

    func selectedRange(of element: AXUIElement) -> CFRange? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &valueRef) == .success,
              let valueRef = valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID()
        else { return nil }

        let axValue = valueRef as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    func setSelectedRange(_ range: Range<Int>, of element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
        return err == .success
    }

    /// Replaces the current selection with `text` through AX.
    ///
    /// Preferred over the clipboard path: it leaves the pasteboard untouched and
    /// needs no synthetic keystrokes. Returns false when the element refuses the
    /// write, so the caller can fall back.
    func replaceSelectedText(_ text: String, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            flog("replaceSelectedText: kAXSelectedText not settable")
            return false
        }

        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if err != .success {
            flog("replaceSelectedText: set failed, err=\(err.rawValue)")
        }
        return err == .success
    }

    // MARK: - Synthetic keystrokes

    /// Posts a key down/up pair with the given modifier flags.
    func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else {
            flog("postKeystroke: FAILED to create events for key \(virtualKey)")
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Pasteboard snapshot

    /// Deep copy of the current pasteboard so a synthetic copy/paste round-trip
    /// can put the user's clipboard back exactly as it was — including non-text
    /// flavors, which the older string-only restore in `pasteViaClipboard` drops.
    func snapshotPasteboard() -> [NSPasteboardItem] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restorePasteboard(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
