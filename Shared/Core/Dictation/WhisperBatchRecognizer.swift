import Foundation

/// Whisper over the whole recording at once: collects audio until key up and
/// transcribes it in one go. Emits no events — nothing is stable before the end.
final class WhisperBatchRecognizer: SpeechRecognizer {
    let events: AsyncStream<TranscriptEvent>
    let displayName: String

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let engine: TranscriptionEngine
    /// The dictation dictionary, fitted into a prompt on the transcription thread.
    private let promptTerms: [String]?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var cancelled = false

    init(engine: TranscriptionEngine, displayName: String, promptTerms: [String]? = nil) {
        self.engine = engine
        self.displayName = displayName
        self.promptTerms = promptTerms
        var continuation: AsyncStream<TranscriptEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start() async throws {}

    func append(_ samples: [Float]) {
        lock.lock()
        self.samples.append(contentsOf: samples)
        lock.unlock()
    }

    func finish() async throws -> TranscriptionResult {
        defer { continuation.finish() }
        let captured = takeSamples()
        flog("whisperBatch: transcribing \(captured.count) samples")
        let options = TranscriptionOptions(promptTerms: promptTerms,
                                           promptTokens: DictationDictionary.maxTokens)
        return try await engine.transcribe(samples: captured, options: options, shouldCancel: { [weak self] in
            self?.isCancelled ?? true
        })
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        continuation.finish()
    }

    private func takeSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return captured
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
