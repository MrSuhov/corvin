import AppKit

/// Puts recognised text into the focused app.
final class TextInsertionSink: TranscriptSink {
    enum Mode {
        /// Paste the whole utterance once the key is released.
        case onRelease
        /// Type each committed chunk as it arrives.
        case asCommitted
    }

    private let accessibility: AccessibilityService
    private let mode: Mode
    private lazy var inserter = IncrementalTextInserter(accessibility: accessibility)

    init(accessibility: AccessibilityService, mode: Mode) {
        self.accessibility = accessibility
        self.mode = mode
    }

    func handle(_ event: TranscriptEvent) {
        switch (mode, event) {
        case (.asCommitted, .committed(let chunk)):
            inserter.type(chunk.text)
        case (.onRelease, .finished(let result)):
            flog("insertion: calling accessibilityService.insertText")
            accessibility.insertText(result.text)
        default:
            break
        }
    }
}

final class ClipboardSink: TranscriptSink {
    func handle(_ event: TranscriptEvent) {
        guard case .finished(let result) = event else { return }
        flog("insertion: copying to clipboard")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
    }
}
