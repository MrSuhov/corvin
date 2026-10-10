import Foundation

/// Term lists as people type or paste them.
enum TermList {
    /// One term per line; commas and semicolons separate terms too, so a list
    /// pasted from a document works. Blank and repeated (case-insensitive)
    /// entries are dropped, first spelling wins.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: "\n\r,;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// The terms everyday dictation should expect — fn on macOS, the keyboard on
/// iOS — given to whisper as an initial prompt. One per device, kept as the
/// text the user typed, comments included, so the editor shows it back as is.
///
/// Off by default: a Russian prompt before every dictation pulls whisper
/// towards Russian, which breaks English or Spanish dictation on auto-detect.
/// The example is there from the start; using it is the user's choice.
enum DictationDictionary {
    static let textKey = "dictationDictionary.text"
    static let enabledKey = "dictationDictionary.enabled"

    /// Prompt tokens the dictionary may take. Streaming dictation puts the
    /// recent text (≤200 characters, ~100 tokens) after it, and whisper keeps
    /// only the last 224 prompt tokens — dropping the start, the dictionary.
    static let maxTokens = 100

    /// iOS keeps it in the app group like the other settings: the host app
    /// transcribes and reads it, the settings screen writes it.
    static var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: SharedDefaults.appGroup) ?? .standard
        #else
        return .standard
        #endif
    }

    static var exampleText: String { "dictation.dictionary.example".localized }

    /// The stored text, or the example until the user has saved one.
    static var text: String {
        get { defaults.string(forKey: textKey) ?? exampleText }
        set { defaults.set(newValue, forKey: textKey) }
    }

    /// Writes the text and reads it back; false if the store did not keep it.
    /// The editors say "Saved" only on true. A save is what sync compares:
    /// the later one wins on every device.
    @discardableResult
    static func save(_ newText: String) -> Bool {
        text = newText
        savedAtMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let kept = defaults.string(forKey: textKey) == newText
        if kept { onSave?() }
        return kept
    }

    // MARK: - Sync

    static let savedAtKey = "dictationDictionary.savedAt"

    /// Posted on the main queue when another device's dictionary replaced this one.
    static let didChangeNotification = Notification.Name("DictationDictionary.didChange")

    /// Set by `DictionarySync`: a local save is pushed to the paired devices.
    static var onSave: (() -> Void)?

    /// When the text was last saved on any device; nil until it has been.
    static var savedAtMs: Int64? {
        get { (defaults.object(forKey: savedAtKey) as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: savedAtKey) }
    }

    static var state: DictionaryState { DictionaryState(text: text, savedAtMs: savedAtMs) }

    /// Takes another device's dictionary, keeping *its* save time — stamping
    /// "now" would make the two devices bounce the text back and forth.
    static func adopt(_ remote: DictionaryState) {
        guard let time = remote.savedAtMs else { return }
        let changed = remote.text != text
        text = remote.text
        savedAtMs = time
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Terms for the next dictation; nil when the dictionary is off or empty.
    static var activeTerms: [String]? {
        guard isEnabled else { return nil }
        let list = terms(from: text)
        return list.isEmpty ? nil : list
    }

    /// Lines starting with `#` are instructions, not terms.
    static func terms(from text: String) -> [String] {
        let content = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        return TermList.parse(content)
    }
}
