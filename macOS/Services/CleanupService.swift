import Foundation

/// How long something is kept. `never` is the default everywhere: deleting a
/// user's recordings is not something to switch on for them.
enum CleanupPeriod: String, CaseIterable, Identifiable {
    case never, week, month, halfYear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "settings.history.period.never".localized
        case .week: return "settings.history.period.week".localized
        case .month: return "settings.history.period.month".localized
        case .halfYear: return "settings.history.period.halfYear".localized
        }
    }

    /// Anything older than this goes; nil keeps everything.
    func cutoff(from now: Date) -> Date? {
        switch self {
        case .never: return nil
        case .week: return Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now)
        case .month: return Calendar.current.date(byAdding: .month, value: -1, to: now)
        case .halfYear: return Calendar.current.date(byAdding: .month, value: -6, to: now)
        }
    }

    static func stored(_ key: String) -> CleanupPeriod {
        CleanupPeriod(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .never
    }
}

enum CleanupSettings {
    static let callAudioKey = "callAudioCleanupPeriod"
    static let transcriptsKey = "transcriptCleanupPeriod"
    /// Shared with iOS through the app group, so it keeps its old name: a
    /// rename would silently change what iOS does.
    static let dictationKey = "autoCleanupPeriod"
    static let lastRunKey = "lastCleanupRun"

    static let defaults: [String: Any] = [
        callAudioKey: CleanupPeriod.never.rawValue,
        transcriptsKey: CleanupPeriod.never.rawValue,
    ]
}

/// What a cleanup run would delete.
///
/// Pure, and the whole point of the design: deleting files is irreversible, so
/// the rules are decided in one testable function with no file system or clock
/// of its own.
struct CleanupPlan: Equatable {
    var audio: [URL] = []
    var transcripts: [URL] = []
    /// Dictation rows older than this go; nil leaves the history alone.
    var dictationCutoff: Date?

    var isEmpty: Bool { audio.isEmpty && transcripts.isEmpty && dictationCutoff == nil }

    struct Input {
        var now: Date
        var callAudio: CleanupPeriod
        var transcripts: CleanupPeriod
        var dictation: CleanupPeriod
        /// Everything the transcript registry remembers.
        var records: [TranscriptRegistry.Record]
        /// Audio paths the call index knows — recordings Corvin made itself.
        var calls: Set<String>
        /// Folders Corvin puts finished call recordings in.
        var callDirectories: [URL]
        /// Paths nothing may touch: queued for transcription, or recording now.
        var protected: Set<String>
        var contents: (URL) -> [URL]
        var modified: (URL) -> Date?
    }

    /// Only files Corvin created are ever considered: a call it recorded, or a
    /// transcript it wrote. The user's own audio — including anything else
    /// sitting in the chosen output folder — is never a candidate.
    static func make(_ input: Input) -> CleanupPlan {
        var plan = CleanupPlan()
        plan.dictationCutoff = input.dictation.cutoff(from: input.now)

        if let cutoff = input.callAudio.cutoff(from: input.now) {
            var candidates = input.calls
            // Calls recorded before the index existed are still marked in the
            // registry.
            for record in input.records where record.roles?.isCall == true {
                candidates.insert(record.sourcePath)
            }
            // And recordings whose transcription never ran, sitting in Corvin's
            // own calls folders.
            for directory in input.callDirectories {
                for url in input.contents(directory)
                where AudioFileDecoder.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    candidates.insert(url.standardizedFileURL.path)
                }
            }
            plan.audio = candidates
                .subtracting(input.protected)
                .compactMap { path in
                    let url = URL(fileURLWithPath: path)
                    guard let modified = input.modified(url), modified < cutoff else { return nil }
                    return url
                }
                .sorted { $0.path < $1.path }
        }

        if let cutoff = input.transcripts.cutoff(from: input.now) {
            plan.transcripts = input.records
                .flatMap { [$0.plain, $0.roles].compactMap { $0 } }
                .filter { $0.date < cutoff }
                .map { $0.outputURL }
                .filter { input.modified($0) != nil }
                .sorted { $0.path < $1.path }
        }

        return plan
    }
}

/// Runs `CleanupPlan` on a schedule.
///
/// The setting existed for a long time and never ran: `performAutoCleanup()`
/// had no callers at all. This is the thing that makes it real, which is also
/// why every deletion is logged and why nothing is on by default.
@MainActor
final class CleanupService: ObservableObject {

    struct Summary: Equatable {
        var files = 0
        var bytes: Int64 = 0
        var dictationRows = 0
    }

    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: Summary?
    @Published private(set) var isRunning = false

    /// Not more often than this, unless the user presses the button.
    private static let minimumInterval: TimeInterval = 12 * 3600
    private static let checkInterval: TimeInterval = 6 * 3600
    /// Long enough for `CallRecorder` to have claimed whatever was left in
    /// `Recordings` after a crash.
    private static let launchDelay: TimeInterval = 8

    private let registry: TranscriptRegistry
    private let callIndex: CallIndex
    private let historyStore: HistoryStore
    private let fileQueue: FileTranscriptionQueue
    private var timer: Timer?

    init(registry: TranscriptRegistry, callIndex: CallIndex,
         historyStore: HistoryStore, fileQueue: FileTranscriptionQueue) {
        self.registry = registry
        self.callIndex = callIndex
        self.historyStore = historyStore
        self.fileQueue = fileQueue
        lastRun = UserDefaults.standard.object(forKey: CleanupSettings.lastRunKey) as? Date
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.run()
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run() }
        }
        // Nothing here is urgent; let the system batch the wake-up.
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// - Parameter force: ignore the 12-hour spacing, for the "Clean up now" button.
    func run(force: Bool = false) {
        guard !isRunning else { return }
        if !force, let lastRun, Date().timeIntervalSince(lastRun) < Self.minimumInterval { return }

        let plan = makePlan()
        guard !plan.isEmpty else {
            record(Summary())
            return
        }
        flog("Cleanup: \(plan.audio.count) recording(s), \(plan.transcripts.count) transcript(s)"
             + (plan.dictationCutoff == nil ? "" : ", dictation before \(plan.dictationCutoff!)"))

        isRunning = true
        Task {
            var summary = await Task.detached(priority: .utility) { Self.delete(plan) }.value
            if let cutoff = plan.dictationCutoff {
                summary.dictationRows = historyStore.deleteRecords(olderThan: cutoff)
            }
            // The list must not keep offering files that are gone.
            registry.forgetMissingTranscripts()
            callIndex.prune(keeping: Set(registry.records.map { $0.sourcePath }))
            isRunning = false
            record(summary)
        }
    }

    private func makePlan() -> CleanupPlan {
        let protected = Set(fileQueue.jobs.filter { !$0.status.isFinished }
            .map { $0.url.standardizedFileURL.path })
        return CleanupPlan.make(CleanupPlan.Input(
            now: Date(),
            callAudio: .stored(CleanupSettings.callAudioKey),
            transcripts: .stored(CleanupSettings.transcriptsKey),
            dictation: .stored(CleanupSettings.dictationKey),
            records: registry.records,
            calls: Set(callIndex.calls.keys),
            callDirectories: [CallRecorder.defaultCallsDirectory, CallRecorder.fallbackCallsDirectory],
            protected: protected,
            contents: { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] },
            modified: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        ))
    }

    private func record(_ summary: Summary) {
        lastSummary = summary
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: CleanupSettings.lastRunKey)
    }

    private nonisolated static func delete(_ plan: CleanupPlan) -> Summary {
        var summary = Summary()
        for url in plan.audio + plan.transcripts {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                summary.files += 1
                summary.bytes += size
                flog("Cleanup: deleted \(url.path) (\(size) bytes)")
            } catch {
                flog("Cleanup: could not delete \(url.path): \(error)")
            }
        }
        return summary
    }
}
