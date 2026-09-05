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

    /// Keyboard presence signalling. The keyboard extension cannot launch the host app,
    /// so these double as a liveness probe: a successful call means the host is awake.
    static let keyboardActiveURL = URL(string: "http://127.0.0.1:12345/keyboard-active")!
    static let keyboardInactiveURL = URL(string: "http://127.0.0.1:12345/keyboard-inactive")!
    static let pingURL = URL(string: "http://127.0.0.1:12345/ping")!

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

/// Keys shared between the host app and the keyboard extension via the App Group.
enum SharedDefaults {
    static let appGroup = "group.com.corvinvoice.app"

    /// User intent for background mode, persisted across launches.
    static let backgroundModeEnabled = "backgroundModeEnabled"
    /// Unix timestamp refreshed by the host's keep-alive watchdog. The keyboard reads it
    /// to tell "host is asleep" apart from "the request happened to fail".
    static let hostAliveAt = "hostAliveAt"
    /// UI language chosen in the app ("" = follow the system). The keyboard extension
    /// reads it so its own strings come up in the same language as the app.
    static let appLanguage = "appLanguage"
    /// Comma-separated input locales for the keyboard, e.g. "en,ru". Legacy format.
    static let keyboardLanguages = "keyboardLanguages"
}
