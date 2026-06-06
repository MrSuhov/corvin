import Foundation

/// Async HTTP-based IPC over localhost.
/// POST /transcribe returns immediately with request ID.
/// GET /result?id=xxx polls for the transcription result.
enum IPCConfig {
    static let port: UInt16 = 12345
    static let transcribeURL = URL(string: "http://127.0.0.1:12345/transcribe")!
    static let resultBaseURL = "http://127.0.0.1:12345/result?id="
    static let pollInterval: TimeInterval = 0.5
    static let pollTimeout: TimeInterval = 120

    static let startRecordingURL = URL(string: "http://127.0.0.1:12345/start-recording")!
    static let stopRecordingURL = URL(string: "http://127.0.0.1:12345/stop-recording")!

    static func resultURL(for id: String) -> URL {
        URL(string: "\(resultBaseURL)\(id)")!
    }
}

struct IPCSubmitResponse: Codable {
    let id: String
}

struct IPCResultResponse: Codable {
    let status: String // "processing" or "done" or "error"
    let text: String?
    let language: String?
    let error: String?
}
