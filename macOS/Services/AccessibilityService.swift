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
    /// The tree is built asynchronously, so the first attempt in such an app sees
    /// nothing and later ones do. Only reads are ever taken from it.
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

    var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// AX role of an element, for diagnostics — it's the quickest way to tell a
    /// real text field from an Electron app's hidden screen-reader textarea.
    func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
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

    // MARK: - Synthetic keystrokes

    /// Events posted from a `.hidSystemState` source inherit the modifiers the
    /// user is physically holding, OR-ed on top of whatever flags we set. That
    /// is fatal right after an Option tap: the key-up is still propagating, so a
    /// posted ⌘C arrives as ⌥⌘C and the app doesn't treat it as Copy. A private
    /// source carries no hardware state, so the flags are exactly ours.
    private static let syntheticSource = CGEventSource(stateID: .privateState)

    /// Posts a key down/up pair with the given modifier flags.
    func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = Self.syntheticSource
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
