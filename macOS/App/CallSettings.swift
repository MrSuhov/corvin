import Foundation

/// Settings of call recording. Recording itself starts from the menubar; this
/// is the only knob, a section of the Settings tab (`CallSettingsView`).
enum CallSettings {
    static let chunkMinutesKey = "callRecording.chunkMinutes"

    static let defaults: [String: Any] = [
        chunkMinutesKey: 5,
    ]

    static let chunkRange = 1...30

    /// How long one part of a recording is.
    ///
    /// Each finished part is a closed file on disk, so an hour-long call never
    /// depends on a single write at the end: a crash costs at most the part in
    /// flight. The parts are merged into one file when the call ends.
    static var chunkDuration: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: chunkMinutesKey)
        return TimeInterval(min(max(minutes, chunkRange.lowerBound), chunkRange.upperBound) * 60)
    }
}
