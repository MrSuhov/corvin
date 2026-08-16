import Foundation
#if os(macOS)
import Carbon
#endif

/// Physical-key mapping between the US QWERTY and Russian ЙЦУКЕН layouts —
/// the "Punto Switcher" transform: take text that was typed with the wrong
/// input source active and re-render it as if the other one had been active.
///
/// On macOS the table is derived at runtime from the two keyboard layouts the
/// user actually has enabled (see `derivedTables`); the hand-written table below
/// is only a fallback. A static table cannot be right for everyone: which
/// character a key produces depends on the layout variant (Apple's "Russian" and
/// "Russian — PC" disagree about punctuation) *and* on the keyboard's physical
/// type. On an ISO keyboard `ё` sits on the section key left of `1` — `§` in the
/// US layout — while on ANSI it sits on the grave key. Guessing one of those
/// silently breaks the other.
///
/// Both directions are stored as explicit dictionaries rather than deriving one
/// by inverting the other. Several characters (`"`, `,`, `.`, `;`, `:`, `?`)
/// exist in *both* layouts but sit on *different* physical keys, so a single
/// dictionary plus inversion would collide: `"` is Shift+quote in US (→ `Э`)
/// but Shift+2 in Russian (→ `@`).
enum LayoutMapper {

    enum Direction {
        /// Text was typed on the US layout; render it as the Russian layout would.
        case enToRu
        /// Text was typed on the Russian layout; render it as the US layout would.
        case ruToEn

        var flipped: Direction { self == .enToRu ? .ruToEn : .enToRu }
    }

    // MARK: - Fallback table

    /// (US character, Russian character) produced by the same physical key,
    /// assuming an ANSI keyboard and the "Russian — PC" layout.
    ///
    /// Used only when the live layouts can't be read — no Russian input source
    /// enabled, or a platform without Text Input Sources at all.
    private static let pairs: [(Character, Character)] = [
        // Number row (only the keys where the two layouts differ)
        ("`", "ё"), ("~", "Ё"),
        ("@", "\""), ("#", "№"), ("$", ";"), ("^", ":"), ("&", "?"),

        // Top letter row
        ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"), ("y", "н"),
        ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"), ("[", "х"), ("]", "ъ"),
        ("Q", "Й"), ("W", "Ц"), ("E", "У"), ("R", "К"), ("T", "Е"), ("Y", "Н"),
        ("U", "Г"), ("I", "Ш"), ("O", "Щ"), ("P", "З"), ("{", "Х"), ("}", "Ъ"),

        // Home row
        ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"), ("h", "р"),
        ("j", "о"), ("k", "л"), ("l", "д"), (";", "ж"), ("'", "э"),
        ("A", "Ф"), ("S", "Ы"), ("D", "В"), ("F", "А"), ("G", "П"), ("H", "Р"),
        ("J", "О"), ("K", "Л"), ("L", "Д"), (":", "Ж"), ("\"", "Э"),

        // Bottom row
        ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"),
        ("m", "ь"), (",", "б"), (".", "ю"), ("/", "."),
        ("Z", "Я"), ("X", "Ч"), ("C", "С"), ("V", "М"), ("B", "И"), ("N", "Т"),
        ("M", "Ь"), ("<", "Б"), (">", "Ю"), ("?", ","),
    ]

    struct Tables {
        let enToRu: [Character: Character]
        let ruToEn: [Character: Character]

        func table(for direction: Direction) -> [Character: Character] {
            direction == .enToRu ? enToRu : ruToEn
        }
    }

    private static let fallbackTables = Tables(
        enToRu: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) }),
        ruToEn: Dictionary(uniqueKeysWithValues: pairs.map { ($0.1, $0.0) })
    )

    // MARK: - Conversion

    /// Re-renders `text` in the other layout. Characters absent from the table
    /// (digits, spaces, emoji, characters from a third alphabet) pass through
    /// unchanged, so mixed-language selections degrade gracefully instead of
    /// being mangled.
    static func convert(_ text: String, direction: Direction) -> String {
        let table = tables.table(for: direction)
        return String(text.map { table[$0] ?? $0 })
    }

    /// Converts using the direction inferred from the text itself.
    static func convert(_ text: String) -> String {
        convert(text, direction: detectDirection(text))
    }

    /// Picks a direction by counting which alphabet dominates the text.
    ///
    /// Ties — including text with no letters at all — resolve to `.enToRu`,
    /// matching the common case of Latin gibberish that should have been
    /// Russian. Applying one direction to the whole string (rather than
    /// per-character) keeps the transform reversible: pressing the hotkey twice
    /// returns the original text.
    static func detectDirection(_ text: String) -> Direction {
        var cyrillic = 0
        var latin = 0
        for ch in text.unicodeScalars {
            if (ch.value >= 0x0410 && ch.value <= 0x044F) || ch.value == 0x0401 || ch.value == 0x0451 {
                cyrillic += 1
            } else if (ch.value >= 0x41 && ch.value <= 0x5A) || (ch.value >= 0x61 && ch.value <= 0x7A) {
                latin += 1
            }
        }
        return cyrillic > latin ? .ruToEn : .enToRu
    }
}

// MARK: - Runtime derivation from the enabled keyboard layouts

#if os(macOS)
extension LayoutMapper {

    private static let cacheLock = NSLock()
    private static var cachedTables: Tables?
    private static var isObservingInputSources = false

    /// The pairing in force right now, derived from the user's own layouts and
    /// keyboard, falling back to the built-in table.
    static var tables: Tables {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if !isObservingInputSources {
            isObservingInputSources = true
            // Enabling or removing a layout changes the answer.
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                object: nil,
                queue: nil
            ) { _ in
                cacheLock.lock()
                cachedTables = nil
                cacheLock.unlock()
            }
        }

        if let cached = cachedTables { return cached }
        let resolved = derivedTables() ?? fallbackTables
        cachedTables = resolved
        return resolved
    }

    /// Asks the layouts themselves what each physical key produces, pairing the
    /// two answers per key code. This is the only way to get the mapping right
    /// across layout variants and keyboard types — see the note on the enum.
    ///
    /// Returns nil when either layout is missing or the result looks too sparse
    /// to be a real alphabet, so the caller can fall back rather than install a
    /// half-empty table.
    private static func derivedTables() -> Tables? {
        guard let en = enabledKeyboardSource(language: "en"),
              let ru = enabledKeyboardSource(language: "ru")
        else { return nil }

        var enToRu: [Character: Character] = [:]
        var ruToEn: [Character: Character] = [:]

        for keyCode in keyCodesToScan() {
            for shifted in [false, true] {
                guard let latin = character(from: en, keyCode: keyCode, shifted: shifted),
                      let cyrillic = character(from: ru, keyCode: keyCode, shifted: shifted),
                      // Keys both layouts agree on (digits, `-`, `=`) need no entry.
                      latin != cyrillic
                else { continue }

                // First key code wins: a character reachable from two keys —
                // `ё` from the section key and, on some layouts, elsewhere —
                // should convert back to the one the user actually pressed, and
                // `keyCodesToScan` puts that one first.
                if enToRu[latin] == nil { enToRu[latin] = cyrillic }
                if ruToEn[cyrillic] == nil { ruToEn[cyrillic] = latin }
            }
        }

        guard enToRu.count >= 30 else { return nil }
        return Tables(enToRu: enToRu, ruToEn: ruToEn)
    }

    /// The alphanumeric block. Key codes that produce whitespace or control
    /// characters (Return, Tab, Space, Delete) fall inside this range and are
    /// dropped by `character(from:keyCode:shifted:)`.
    private static func keyCodesToScan() -> [UInt16] {
        let isoSection: UInt16 = 0x0A
        var codes: [UInt16] = []
        // Only present on ISO keyboards, where it carries `§`/`ё`. On ANSI the
        // layouts still answer for it, but the user has no such key and `ё`
        // must map back to the grave key instead.
        if KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO {
            codes.append(isoSection)
        }
        codes.append(contentsOf: (UInt16(0x00)...UInt16(0x33)).filter { $0 != isoSection })
        return codes
    }

    private static func enabledKeyboardSource(language: String) -> TISInputSource? {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return sources.first { source in
            property(source, kTISPropertyInputSourceCategory) as? String
                == (kTISCategoryKeyboardInputSource as String)
                && property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true
                && property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true
                && (property(source, kTISPropertyInputSourceLanguages) as? [String])?.first == language
        }
    }

    private static func character(from source: TISInputSource, keyCode: UInt16, shifted: Bool) -> Character? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let modifiers = UInt32(shifted ? (shiftKey >> 8) : 0)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
        }

        // Anything that isn't exactly one printable character — a dead key, a
        // ligature, Return — has no place in a per-character table.
        guard status == noErr, length == 1,
              let scalar = Unicode.Scalar(characters[0]),
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return Character(scalar)
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
#else
extension LayoutMapper {
    static var tables: Tables { fallbackTables }
}
#endif
