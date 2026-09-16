import Foundation

/// What a call recording was: which app it came from, when it started, how long
/// it ran.
///
/// Deliberately not a field on `TranscriptRegistry.Record`: a registry row
/// appears only once a transcript has been saved, so a call that has not been
/// transcribed yet — or whose transcription failed — would be invisible in
/// History. The file name cannot stand in for this either: it is localized
/// ("Звонок Telegram …"), so the app name cannot be read back out of it.
struct CallInfo: Codable, Equatable {
    var bundleID: String
    var appName: String
    var startedAt: Date
    /// Seconds of audio; nil when the length was never measured.
    var duration: TimeInterval?
    var partCount: Int
    /// Merged at the next launch after a quit or a crash, rather than on Stop.
    var recoveredAfterCrash: Bool

    init(bundleID: String, appName: String, startedAt: Date, duration: TimeInterval? = nil,
         partCount: Int = 0, recoveredAfterCrash: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.startedAt = startedAt
        self.duration = duration
        self.partCount = partCount
        self.recoveredAfterCrash = recoveredAfterCrash
    }
}

extension CallInfo {
    /// Read the side-car written next to a recording's parts. Absent for calls
    /// recorded before side-cars existed, so a nil answer is normal.
    static func read(_ url: URL) -> CallInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CallInfo.self, from: data)
    }

    /// Written before the call's first part is closed, so the app that was
    /// recorded survives even a `kill -9`.
    func write(to url: URL) {
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            flog("CallInfo: could not write \(url.lastPathComponent): \(error)")
        }
    }
}

/// Every call recording Corvin has made, keyed by the path of its audio file.
@MainActor
final class CallIndex: ObservableObject {

    @Published private(set) var calls: [String: CallInfo] = [:]

    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Corvin/calls.json")
        load()
    }

    func info(for url: URL) -> CallInfo? {
        calls[Self.key(url)]
    }

    func record(_ info: CallInfo, for url: URL) {
        calls[Self.key(url)] = info
        persist()
    }

    func remove(_ url: URL) {
        guard calls.removeValue(forKey: Self.key(url)) != nil else { return }
        persist()
    }

    func removeAll() {
        guard !calls.isEmpty else { return }
        calls = [:]
        persist()
    }

    /// Forget calls whose audio is gone and that nothing else still lists.
    /// - Parameter referenced: paths to keep regardless, e.g. everything the
    ///   transcript registry remembers.
    func prune(keeping referenced: Set<String> = []) {
        let stale = calls.keys.filter {
            !referenced.contains($0) && !FileManager.default.fileExists(atPath: $0)
        }
        guard !stale.isEmpty else { return }
        for key in stale { calls[key] = nil }
        flog("CallIndex: forgot \(stale.count) call(s) whose audio is gone")
        persist()
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            calls = try JSONDecoder().decode([String: CallInfo].self, from: data)
        } catch {
            flog("CallIndex: could not read \(file.path): \(error)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(calls).write(to: file, options: .atomic)
        } catch {
            flog("CallIndex: could not write \(file.path): \(error)")
        }
    }
}
