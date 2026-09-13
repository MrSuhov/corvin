import Foundation

final class HistorySink: TranscriptSink {
    private let store: HistoryStore
    private let modelUsed: String
    private let recordingDuration: () -> TimeInterval

    /// - Parameter recordingDuration: read when the utterance is finished, so it
    ///   can measure up to key release rather than up to the end of transcription.
    init(store: HistoryStore, modelUsed: String, recordingDuration: @escaping () -> TimeInterval) {
        self.store = store
        self.modelUsed = modelUsed
        self.recordingDuration = recordingDuration
    }

    func handle(_ event: TranscriptEvent) {
        guard case .finished(let result) = event else { return }
        let duration = recordingDuration()
        store.addRecord(
            text: result.text,
            duration: duration,
            modelUsed: modelUsed,
            language: result.language
        )
        flog("history: saved, duration=\(String(format: "%.1f", duration))s")
    }
}
