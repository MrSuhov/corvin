import Foundation
import AppKit
import ApplicationServices

class AccessibilityService {
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
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
}
