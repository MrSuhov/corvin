import Foundation
import AppKit
import Combine

/// Serial batch transcription of audio files dropped on, or picked in, the
/// Transcription settings pane.
///
/// Owned by `AppDelegate` and injected as an `@EnvironmentObject` rather than
/// held by the view: `SettingsView` rebuilds its detail pane with a `switch`
/// and carries `.id(currentLanguage)`, so anything the view owns dies when the
/// user changes tabs or switches the interface language — mid-batch.
@MainActor
final class FileTranscriptionQueue: ObservableObject {

    // MARK: - Model

    enum Status: Equatable {
        case pending
        /// Parked so the fn-hotkey dictation flow can have the engine.
        case waitingForMic
        case decoding
        case transcribing
        case saved
        /// Written to Application Support because the target folder refused it.
        case savedToFallback
        /// Transcribed to nothing — silence, or too short to run at all.
        case empty
        case failed

        var isFinished: Bool {
            switch self {
            case .saved, .savedToFallback, .empty, .failed: return true
            case .pending, .waitingForMic, .decoding, .transcribing: return false
            }
        }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var status: Status = .pending
        var progress: ChunkProgress = .none
        var startedAt: Date?
        /// Kept after a failed save so the row can offer "Save as…".
        var text: String?
        var outputURL: URL?
        var error: String?
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var stopRequested = false
    /// Directories the last permission check found unwritable, for the banner.
    @Published private(set) var blockedDirectories: [URL] = []

    /// User-chosen destination for every transcript. Empty means "next to the
    /// audio file". Unsandboxed, so a plain path is enough — no bookmark.
    @Published var outputDirectory: URL? {
        didSet {
            UserDefaults.standard.set(outputDirectory?.path, forKey: Self.outputDirectoryKey)
        }
    }

    static let outputDirectoryKey = "transcriptOutputDirectory"

    /// Files this large are refused before decoding. `AudioFileDecoder` builds
    /// an `AVAudioPCMBuffer` over the whole file at its source rate and channel
    /// count, so a long stereo recording can cost multiple gigabytes of RAM
    /// before whisper ever sees it. Single-file import made that unlikely;
    /// "drag in a folder of podcasts" makes it routine.
    static let maxFileSize: Int64 = 512 * 1024 * 1024

    // MARK: - Dependencies

    private let engine: TranscriptionEngine
    private let sessionManager: SessionManager
    private let modelManager: ModelManager

    /// Mirror of `sessionManager.state` that is safe to read from the whisper
    /// worker thread; `@Published` properties are only safe on the main queue.
    private let micBusy = AtomicFlag()
    private var cancellables = Set<AnyCancellable>()
    private var runner: Task<Void, Never>?

    init(engine: TranscriptionEngine, sessionManager: SessionManager, modelManager: ModelManager) {
        self.engine = engine
        self.sessionManager = sessionManager
        self.modelManager = modelManager

        if let path = UserDefaults.standard.string(forKey: Self.outputDirectoryKey), !path.isEmpty {
            self.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }

        sessionManager.$state
            .sink { [weak self] state in self?.micBusy.value = (state != .idle) }
            .store(in: &cancellables)

        // Returning from System Settings is the one moment a previously denied
        // folder can have become writable, so drop the cached verdicts.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, !self.blockedDirectories.isEmpty else { return }
                TranscriptSaver.forgetProbeResults()
                self.recheckBlockedDirectories()
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    var finishedCount: Int { jobs.filter { $0.status.isFinished }.count }
    var hasFinishedJobs: Bool { jobs.contains { $0.status.isFinished } }
    var unsavedJobs: [Job] { jobs.filter { $0.status == .failed && $0.text?.isEmpty == false } }

    /// Where a given file's transcript should go.
    func destination(for url: URL) -> URL {
        outputDirectory ?? url.deletingLastPathComponent()
    }

    // MARK: - Enqueueing

    func enqueue(urls: [URL]) {
        let accepted = urls.compactMap(Self.acceptableAudioURL)
        guard !accepted.isEmpty else { return }

        let known = Set(jobs.map { $0.url.standardizedFileURL })
        let fresh = accepted.filter { !known.contains($0.standardizedFileURL) }
        guard !fresh.isEmpty else { return }

        jobs.append(contentsOf: fresh.map { Job(url: $0) })
        flog("FileQueue: enqueued \(fresh.count) file(s), \(jobs.count) total")

        checkWriteAccess(for: fresh)
        start()
    }

    /// Reject folders, bundles, and anything the decoder can't open. Files with
    /// a missing or lying extension get a second chance from the magic bytes —
    /// which is exactly why `sniffFormat` exists.
    static func acceptableAudioURL(_ raw: URL) -> URL? {
        guard raw.isFileURL else { return nil }
        let url = raw.resolvingSymlinksInPath().standardizedFileURL

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory != true,
              values.isPackage != true,
              values.isRegularFile == true
        else { return nil }

        if AudioFileDecoder.supportedExtensions.contains(url.pathExtension.lowercased()) {
            return url
        }
        return AudioFileDecoder.sniffFormat(url: url) != nil ? url : nil
    }

    // MARK: - Permission check

    /// Find out whether transcripts can be written *before* spending minutes on
    /// transcription. Runs off the main thread — a TCC check blocks its caller
    /// for as long as the consent dialog is on screen.
    private func checkWriteAccess(for urls: [URL]) {
        let directories = Set(urls.map { destination(for: $0).standardizedFileURL })

        TranscriptSaver.probeAll(directories) { [weak self] results in
            guard let self else { return }
            let blocked = results.filter { $0.value != .ok }
            self.blockedDirectories = blocked.keys.sorted { $0.path < $1.path }
            guard !blocked.isEmpty else { return }
            self.presentPermissionAlert(blocked)
        }
    }

    private func recheckBlockedDirectories() {
        let directories = Set(blockedDirectories)
        guard !directories.isEmpty else { return }
        TranscriptSaver.probeAll(directories) { [weak self] results in
            guard let self else { return }
            self.blockedDirectories = results.filter { $0.value != .ok }
                .keys.sorted { $0.path < $1.path }
        }
    }

    private func presentPermissionAlert(_ blocked: [URL: TranscriptSaver.WriteAccess]) {
        // Only offer System Settings when a permission is actually the problem;
        // it is no help at all for a read-only volume.
        let recoverableByGrant = blocked.values.contains(.tccDenied)

        let paths = blocked.keys.sorted { $0.path < $1.path }
        let shown = paths.prefix(3).map { abbreviate($0) }
        var detail = shown.joined(separator: "\n")
        if paths.count > shown.count {
            detail += "\n" + "test.perm.andMore".localized(with: paths.count - shown.count)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "test.perm.title".localized
        alert.informativeText = "test.perm.message".localized + "\n\n" + detail
        alert.addButton(withTitle: "test.perm.chooseFolder".localized)
        if recoverableByGrant {
            alert.addButton(withTitle: "test.perm.openSettings".localized)
        }
        alert.addButton(withTitle: "test.perm.continueAnyway".localized)

        // LSUIElement app: without this the alert can open behind everything.
        NSApp.activate(ignoringOtherApps: true)

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.chooseOutputDirectory()
            case .alertSecondButtonReturn where recoverableByGrant:
                Self.openFilesAndFoldersSettings()
            default:
                break  // "transcribe anyway" — the queue is already running
            }
        }

        // Sheet rather than runModal(): this can be reached from a drop
        // completion, and a modal run loop nested inside the drag's own is a
        // reliable way to wedge the UI.
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Picking a directory in an open panel registers a user-intent TCC grant
    /// for that whole subtree, so this recovers even a denied Desktop.
    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "test.output.chooseMessage".localized
        panel.directoryURL = outputDirectory

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        outputDirectory = url
        TranscriptSaver.forgetProbeResults()
        blockedDirectories = []
        checkWriteAccess(for: jobs.filter { !$0.status.isFinished }.map { $0.url })
    }

    func clearOutputDirectory() {
        outputDirectory = nil
        TranscriptSaver.forgetProbeResults()
        blockedDirectories = []
    }

    static func openFilesAndFoldersSettings() {
        // The Settings app changed its URL scheme in Ventura.
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        let string: String
        if #available(macOS 13.0, *) { string = modern } else { string = legacy }
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Queue control

    func requestStop() {
        guard isRunning else { return }
        stopRequested = true
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        if jobs.isEmpty { blockedDirectories = [] }
    }

    private func start() {
        guard runner == nil else { return }
        stopRequested = false
        isRunning = true
        runner = Task { [weak self] in
            await self?.run()
            self?.runner = nil
            self?.isRunning = false
            self?.stopRequested = false
        }
    }

    private func run() async {
        while let next = jobs.first(where: { $0.status == .pending }) {
            if stopRequested {
                flog("FileQueue: stop requested, \(jobs.count - finishedCount) job(s) left pending")
                return
            }
            await process(next.id)
        }
    }

    /// Addressed by id rather than index throughout: the array can be mutated
    /// between awaits (a new drop appends, "Clear" removes finished rows), so a
    /// captured index would drift onto the wrong job.
    private func process(_ jobID: UUID) async {
        guard let url = self[jobID]?.url else { return }
        update(jobID) { $0.startedAt = Date() }

        // Let the hotkey dictation flow finish before starting a new file.
        if micBusy.value {
            update(jobID) { $0.status = .waitingForMic }
            while micBusy.value {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        guard modelManager.activeModel != nil else {
            finish(jobID, .failed, error: "test.noModel".localized)
            return
        }

        // Size guard before decoding — see `maxFileSize`.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        if size > Self.maxFileSize {
            finish(jobID, .failed,
                   error: AudioFileDecoder.DecoderError.fileTooLarge(url.lastPathComponent).localizedDescription)
            return
        }

        update(jobID) { $0.status = .decoding }
        let pcm: Data
        do {
            // Synchronous, reads the whole file — never on the main actor.
            pcm = try await Task.detached(priority: .utility) {
                try AudioFileDecoder.decode(url: url)
            }.value
        } catch {
            flog("FileQueue: decode failed for \(url.lastPathComponent): \(error)")
            finish(jobID, .failed, error: error.localizedDescription)
            return
        }

        update(jobID) { $0.status = .transcribing }
        let busy = micBusy
        let result: TranscriptionResult
        do {
            result = try await engine.transcribe(
                audioData: pcm,
                onProgress: { [weak self] current, total in
                    Task { @MainActor in
                        self?.update(jobID) { $0.progress = ChunkProgress(current: current, total: total) }
                    }
                },
                shouldYield: { busy.value }
            )
        } catch {
            flog("FileQueue: transcribe failed for \(url.lastPathComponent): \(error)")
            finish(jobID, .failed, error: error.localizedDescription)
            return
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finish(jobID, .empty)
            return
        }
        update(jobID) { $0.text = text }

        do {
            let output = try TranscriptSaver.write(text: text,
                                                   audioName: url.lastPathComponent,
                                                   into: destination(for: url))
            update(jobID) { $0.outputURL = output }
            finish(jobID, .saved)
        } catch {
            flog("FileQueue: save failed for \(url.lastPathComponent): \(error)")
            // Don't lose a transcript that cost minutes to produce. Application
            // Support is never TCC-gated, and unlike keeping the text in memory
            // this survives quitting the app.
            do {
                let output = try TranscriptSaver.write(text: text,
                                                       audioName: url.lastPathComponent,
                                                       into: TranscriptSaver.fallbackDirectory)
                update(jobID) { $0.outputURL = output }
                finish(jobID, .savedToFallback)
            } catch {
                finish(jobID, .failed, error: error.localizedDescription)
            }
        }
    }

    private subscript(jobID: UUID) -> Job? {
        jobs.first { $0.id == jobID }
    }

    private func update(_ jobID: UUID, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[index])
    }

    private func finish(_ jobID: UUID, _ status: Status, error: String? = nil) {
        update(jobID) {
            $0.status = status
            $0.error = error
            $0.progress = .none
            $0.startedAt = nil
        }
    }

    // MARK: - Manual saving

    /// Write every transcript that failed to save into a folder the user picks.
    func saveAllUnsaved() {
        let pending = unsavedJobs
        guard !pending.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "test.queue.saveAllMessage".localized

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        for job in pending {
            guard let text = job.text,
                  let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            do {
                let output = try TranscriptSaver.write(text: text,
                                                       audioName: job.url.lastPathComponent,
                                                       into: directory)
                jobs[index].outputURL = output
                jobs[index].status = .saved
                jobs[index].error = nil
            } catch {
                jobs[index].error = error.localizedDescription
            }
        }
    }

    func saveAs(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              let text = jobs[index].text else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = (jobs[index].url.lastPathComponent as NSString)
            .deletingPathExtension + ".txt"
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var body = text
            if !body.hasSuffix("\n") { body += "\n" }
            try Data(body.utf8).write(to: url)
            jobs[index].outputURL = url
            jobs[index].status = .saved
            jobs[index].error = nil
        } catch {
            jobs[index].error = error.localizedDescription
        }
    }

    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Minimal thread-safe boolean. The whisper worker thread polls this to decide
/// whether to step aside, and `@Published` state must not be touched off-main.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
