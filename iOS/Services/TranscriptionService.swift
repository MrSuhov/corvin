import Foundation

class TranscriptionService {
    private let engine: TranscriptionEngine

    init(engine: TranscriptionEngine) {
        self.engine = engine
    }

    func transcribe(audioData: Data) async throws -> TranscriptionResult {
        try await engine.transcribe(audioData: audioData)
    }

    func warmup() {
        engine.warmup()
    }
}
