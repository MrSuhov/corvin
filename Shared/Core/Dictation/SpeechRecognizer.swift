import Foundation

/// Recognised text that will not change any more.
struct TranscriptChunk: Equatable {
    let text: String
}

/// What flows from a recognizer, through `TranscriptPipeline`, to its sinks.
enum TranscriptEvent {
    /// The current guess at speech that is not yet stable. It may be revised
    /// or dropped, so it is never typed into another app.
    case volatile(String)
    /// Stable text delivered while the user is still speaking. Realtime
    /// insertion types exactly these.
    case committed(TranscriptChunk)
    /// The whole utterance after the key was released, already run through
    /// the pipeline's processors. Emitted by the coordinator, not a recognizer.
    case finished(TranscriptionResult)
}

/// One dictation session's worth of speech recognition.
///
/// A recognizer is single-use: created on key down, fed with `append`, closed
/// with `finish` on key up. Audio arrives as 16 kHz mono Float32 on the capture
/// thread, so `append` must be cheap and thread-safe.
///
/// `events` carries `.volatile` and `.committed` only, and ends once `finish`
/// or `cancel` returns. A recognizer that cannot produce stable text before the
/// end — the batch Whisper path — emits nothing there.
protocol SpeechRecognizer: AnyObject {
    var events: AsyncStream<TranscriptEvent> { get }
    /// Stored in history as the model used, e.g. "small" or "Apple Speech (ru-RU)".
    var displayName: String { get }
    func start() async throws
    func append(_ samples: [Float])
    /// The full utterance. For a recognizer that commits as it goes, this is
    /// every committed chunk plus the final tail.
    func finish() async throws -> TranscriptionResult
    func cancel()
}
