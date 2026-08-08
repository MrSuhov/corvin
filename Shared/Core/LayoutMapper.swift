import Foundation

/// Physical-key mapping between the US QWERTY and Russian ЙЦУКЕН layouts —
/// the "Punto Switcher" transform: take text that was typed with the wrong
/// input source active and re-render it as if the other one had been active.
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

    // MARK: - Table

    /// (US character, Russian character) produced by the same physical key.
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

    private static let enToRuTable: [Character: Character] =
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) })

    private static let ruToEnTable: [Character: Character] =
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.1, $0.0) })

    // MARK: - Conversion

    /// Re-renders `text` in the other layout. Characters absent from the table
    /// (digits, spaces, emoji, characters from a third alphabet) pass through
    /// unchanged, so mixed-language selections degrade gracefully instead of
    /// being mangled.
    static func convert(_ text: String, direction: Direction) -> String {
        let table = direction == .enToRu ? enToRuTable : ruToEnTable
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
