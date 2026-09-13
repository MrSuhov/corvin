import Foundation

/// Whisper over the whole recording at once: collects audio until key up and
/// transcribes it in one go. Emits no events — nothing is stable before the end.
final class WhisperBatchRecognizer: SpeechRecognizer {
    let events: AsyncStream<TranscriptEvent>
    let displayName: String

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let engine: TranscriptionEngine
    private let lock = NSLock()
    private var samples: [Float] = []
    private var cancelled = false

    init(engine: TranscriptionEngine, displayName: String) {
        self.engine = engine
        self.displayName = displayName
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
        return try await engine.transcribe(samples: captured, shouldCancel: { [weak self] in
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
