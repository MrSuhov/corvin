import Foundation

/// Shared transcription result type used by IPC protocol.
/// Defined here (not in TranscriptionEngine) so keyboard extension can use it without CWhisper dependency.
struct TranscriptionResult {
    let text: String
    let language: String
}
