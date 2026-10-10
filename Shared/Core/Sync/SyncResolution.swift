import Foundation

/// A dictionary as one device holds it: the text and when it was last saved.
/// `savedAtMs` is whole milliseconds so it survives JSON unchanged — a time
/// that drifted by a rounding error would make two devices trade the same text
/// back and forth.
struct DictionaryState: Equatable {
    let text: String
    /// nil until the user saves on this device: the shipped example never wins.
    let savedAtMs: Int64?
}

/// Which dictionary both sides keep after an exchange.
enum SyncResolution {
    /// Last save wins, whole text. A side that never saved loses to one that
    /// did. On equal times the larger text wins, so two devices that disagree
    /// still end up with the same one.
    static func winner(local: DictionaryState, remote: DictionaryState) -> DictionaryState {
        switch (local.savedAtMs, remote.savedAtMs) {
        case (nil, nil), (_?, nil):
            return local
        case (nil, _?):
            return remote
        case let (l?, r?):
            return r > l || (r == l && remote.text > local.text) ? remote : local
        }
    }
}
