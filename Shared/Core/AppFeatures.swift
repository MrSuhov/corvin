import Foundation

/// Central feature flags. Flip `proEnabled` back to `true` to restore the
/// entire Pro experience (paywall, Pro settings tab/section, app-icon picker).
/// Hidden for now — the app ships completely free.
enum AppFeatures {
    static let proEnabled = false
}
