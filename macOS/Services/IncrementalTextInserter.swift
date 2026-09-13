import Foundation

/// Spacing between chunks that arrive one after another but must read as one
/// sentence in the target field.
struct TextJoiner {
    private(set) var hasOutput = false

    private static let attachesToPrevious = CharacterSet(charactersIn: ",.!?:;…)]}»”")

    /// What to type for `chunk`: trimmed, and preceded by a space unless it is
    /// the first output of the session or starts with closing punctuation.
    mutating func join(_ chunk: String) -> String {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        defer { hasOutput = true }
        guard hasOutput else { return trimmed }
        if let first = trimmed.unicodeScalars.first, Self.attachesToPrevious.contains(first) {
            return trimmed
        }
        return " " + trimmed
    }
}

/// Types committed chunks into the focused app while dictation is still going.
///
/// Unlike `AccessibilityService.insertText`, it never touches the clipboard:
/// a paste per chunk would overwrite the user's clipboard many times a second
/// and race its own restore. Each chunk goes out as Unicode strings on
/// synthetic key events instead.
final class IncrementalTextInserter {
    private let accessibility: AccessibilityService
    private let queue = DispatchQueue(label: "com.corvin.incrementalInsert")
    private var joiner = TextJoiner()

    init(accessibility: AccessibilityService) {
        self.accessibility = accessibility
    }

    /// Call on the main thread. Chunks are typed in call order.
    func type(_ chunk: String) {
        let text = joiner.join(chunk)
        guard !text.isEmpty else { return }
        guard !accessibility.isSecureInputActive else {
            flog("incrementalInsert: secure input active, dropping \(text.count) chars")
            return
        }
        queue.async { [accessibility] in
            accessibility.typeUnicode(text)
        }
    }
}
