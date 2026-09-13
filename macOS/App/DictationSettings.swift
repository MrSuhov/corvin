import Foundation

/// UserDefaults keys and typed reads for the dictation settings.
enum DictationSettings {
    static let realtimeKey = "realtimeDictation"

    static let defaults: [String: Any] = [
        realtimeKey: false,
    ]

    /// Text is typed while the key is held rather than inserted on release.
    static var isRealtimeEnabled: Bool {
        UserDefaults.standard.bool(forKey: realtimeKey)
    }
}
