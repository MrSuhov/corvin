import Foundation

class TranscriptionService {
    private let engine: TranscriptionEngine

    init(engine: TranscriptionEngine) {
        self.engine = engine
    }

    /// Every keyboard dictation comes through here, so this is where the
    /// dictation dictionary joins it. A model without prompt support (GigaAM)
    /// fits no terms and runs as before.
    func transcribe(audioData: Data) async throws -> TranscriptionResult {
        let options = TranscriptionOptions(promptTerms: DictationDictionary.activeTerms,
                                           promptTokens: DictationDictionary.maxTokens)
        let result = try await engine.transcribeTimed(audioData: audioData, options: options)
        return TranscriptionResult(text: result.text, language: result.language)
    }

    func warmup() {
        engine.warmup()
    }
}
