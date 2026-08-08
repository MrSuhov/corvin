import Foundation
import CoreGraphics

/// The modifier keys Corvin can bind a hotkey to, and the translation between a
/// virtual key code and the `CGEventFlags` bit that reports it.
///
/// Both hotkeys need this. Push-to-talk holds a modifier down; layout switching
/// taps one. Neither can use an ordinary key: holding or tapping a letter types
/// it, and a `.defaultTap` event tap that swallowed the keystroke to prevent
/// that would break typing in every app.
///
/// Left and right variants deliberately collapse into one choice — they raise
/// the same flag, and nobody wants "left Option" to behave differently from
/// "right Option".
enum ModifierKey: CaseIterable {
    case option
    case command
    case control
    case shift
    case function

    /// Virtual key codes that produce this modifier, left side first. The first
    /// entry is the canonical value stored in UserDefaults.
    var keyCodes: [Int] {
        switch self {
        case .option:   return [58, 61]
        case .command:  return [55, 54]
        case .control:  return [59, 62]
        case .shift:    return [56, 60]
        case .function: return [63]
        }
    }

    var canonicalKeyCode: Int { keyCodes[0] }

    var flag: CGEventFlags {
        switch self {
        case .option:   return .maskAlternate
        case .command:  return .maskCommand
        case .control:  return .maskControl
        case .shift:    return .maskShift
        case .function: return .maskSecondaryFn
        }
    }

    var symbol: String {
        switch self {
        case .option:   return "⌥"
        case .command:  return "⌘"
        case .control:  return "⌃"
        case .shift:    return "⇧"
        case .function: return "fn"
        }
    }

    /// Caps Lock is intentionally absent: it latches rather than springs back,
    /// so a "tap" of it would leave the keyboard in caps and the flag would stay
    /// raised long after the key was let go.
    static func from(keyCode: Int) -> ModifierKey? {
        allCases.first { $0.keyCodes.contains(keyCode) }
    }

    /// Every modifier flag except this one — the set whose presence means the
    /// user is composing a chord rather than pressing this key on its own.
    var competingFlags: CGEventFlags {
        var flags: CGEventFlags = []
        for key in ModifierKey.allCases where key != self {
            flags.insert(key.flag)
        }
        return flags
    }

    /// Display name for a stored key code, falling back to something readable
    /// for the non-modifier codes older builds may have persisted.
    static func displayName(forKeyCode keyCode: Int) -> String {
        if let modifier = from(keyCode: keyCode) { return modifier.symbol }

        let named: [Int: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 57: "Caps Lock",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return named[keyCode] ?? "Key \(keyCode)"
    }
}
