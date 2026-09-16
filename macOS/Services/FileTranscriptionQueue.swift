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
        /// Dialog mode: finding who speaks when, before whisper runs.
        case diarizing
        case transcribing
        case saved
        /// Written to Application Support because the target folder refused it.
        case savedToFallback
        /// Transcribed to nothing — silence, or too short to run at all.
        case empty
        case failed
        /// Interrupted by a second press of Stop, or by a restart.
        case cancelled

        var isFinished: Bool {
            switch self {
            case .saved, .savedToFallback, .empty, .failed, .cancelled: return true
            case .pending, .waitingForMic, .decoding, .diarizing, .transcribing: return false
            }
        }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// Fixed when queued; the checkbox only affects new jobs and restarts.
        var mode: TranscriptMode
        /// Snapshot of the active vocabulary when queued, so editing it later
        /// does not change a job already waiting.
        var vocabulary: Vocabulary? = nil
        /// Model chosen for this job; nil means the app's active model. Set by
        /// "transcribe again" in History, which must not move the active model.
        var modelID: String? = nil
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
    /// Second press of Stop: abandon the file in flight too, not just the rest.
    @Published private(set) var abortRequested = false
    /// Directories the last permission check found unwritable, for the banner.
    @Published private(set) var blockedDirectories: [URL] = []

    /// User-chosen destination for every transcript. Empty means "next to the
    /// audio file". Unsandboxed, so a plain path is enough — no bookmark.
    @Published var outputDirectory: URL? {
        didSet {
            UserDefaults.standard.set(outputDirectory?.path, forKey: Self.outputDirectoryKey)
        }
    }

    /// The "Dialog recognition" checkbox: new jobs write `<name>_roles.txt`,
    /// split into one paragraph per speaker turn.
    @Published var dialogMode = false {
        didSet {
            UserDefaults.standard.set(dialogMode, forKey: Self.dialogModeKey)
        }
    }

    static let outputDirectoryKey = "transcriptOutputDirectory"
    static let dialogModeKey = "fileTranscription.dialogMode"

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
    private let diarizationModels: DiarizationModelStore
    private let registry: TranscriptRegistry
    private let vocabularies: VocabularyStore
    /// What a recording was: which app, when, how long — for a call
    /// transcript's header. A closure rather than `CallIndex` itself: the queue
    /// has no business knowing how calls are remembered, and `AppDelegate`
    /// owns both sides.
    var callInfo: ((URL) -> CallInfo?)?

    /// Mirror of `sessionManager.state` that is safe to read from the whisper
    /// worker thread; `@Published` properties are only safe on the main queue.
    private let micBusy = AtomicFlag()
    /// Tells the job in flight to stop, polled between chunks, from inside
    /// `whisper_full` and by the diarization helper's watcher. Set by a second
    /// Stop (for good) or by a restart (for that one job).
    private let cancelCurrent = AtomicFlag()
    /// The job to queue again, with the current settings, once its
    /// cancellation lands.
    private var restartJobID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var runner: Task<Void, Never>?

    init(engine: TranscriptionEngine, sessionManager: SessionManager, modelManager: ModelManager,
         diarizationModels: DiarizationModelStore, registry: TranscriptRegistry,
         vocabularies: VocabularyStore) {
        self.engine = engine
        self.sessionManager = sessionManager
        self.modelManager = modelManager
        self.diarizationModels = diarizationModels
        self.registry = registry
        self.vocabularies = vocabularies

        if let path = UserDefaults.standard.string(forKey: Self.outputDirectoryKey), !path.isEmpty {
            self.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        self.dialogMode = UserDefaults.standard.bool(forKey: Self.dialogModeKey)

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

    /// The mode a job queued right now gets. Dialog mode needs macOS 14; on
    /// older systems the checkbox is disabled, and a value synced from a newer
    /// Mac must not turn every job into a failure.
    var currentMode: TranscriptMode {
        dialogMode && DiarizationClient.isSupportedSystem ? .roles : .plain
    }

    /// Where a given file's transcript should go.
    func destination(for url: URL) -> URL {
        outputDirectory ?? url.deletingLastPathComponent()
    }

    // MARK: - Enqueueing

    func enqueue(urls: [URL]) {
        enqueue(urls: urls, mode: currentMode)
    }

    /// "Transcribe again" on a file from the transcribed list, with the
    /// current checkbox.
    /// - Parameter modelID: model to run this time; nil keeps the active one.
    func rerun(_ url: URL, modelID: String? = nil) {
        // A call recording is transcribed as a call again: its channels are
        // what tell the speakers apart.
        enqueue(urls: [url], mode: registry.mode(for: url) ?? currentMode, modelID: modelID)
    }

    /// A finished call recording: two channels, the user and the other side.
    func enqueueCall(_ url: URL) {
        enqueue(urls: [url], mode: .call)
    }

    private func enqueue(urls: [URL], mode: TranscriptMode, modelID: String? = nil) {
        let accepted = urls.compactMap(Self.acceptableAudioURL)
        guard !accepted.isEmpty else { return }

        // The same file in the same mode already waiting or running adds
        // nothing. A finished row makes way instead, so queuing a file again
        // transcribes it again.
        let busy = Set(jobs.filter { !$0.status.isFinished && $0.mode == mode }.map { $0.url.standardizedFileURL })
        let fresh = accepted.filter { !busy.contains($0.standardizedFileURL) }
        guard !fresh.isEmpty else { return }

        let freshSet = Set(fresh.map { $0.standardizedFileURL })
        jobs.removeAll { $0.status.isFinished && $0.mode == mode && freshSet.contains($0.url.standardizedFileURL) }
        jobs.append(contentsOf: fresh.map {
            Job(url: $0, mode: mode, vocabulary: vocabularies.active, modelID: modelID)
        })
        flog("FileQueue: enqueued \(fresh.count) file(s) as \(mode.rawValue), \(jobs.count) total")

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

    /// First press: finish the current file, skip the rest. Second press:
    /// abandon the current file as well.
    func requestStop() {
        guard isRunning else { return }
        if stopRequested {
            abortRequested = true
            cancelCurrent.value = true
            flog("FileQueue: abort requested, interrupting the current file")
        } else {
            stopRequested = true
        }
    }

    /// Run a job again with the current settings — typically after flipping
    /// dialog mode once it had started. A running job is interrupted and takes
    /// its place again at the same position; the rest of the queue is untouched.
    func stopAndRestart(_ jobID: UUID) {
        guard let job = self[jobID] else { return }
        switch job.status {
        case .pending:
            update(jobID) {
                $0.mode = restartMode(for: $0.mode)
                $0.vocabulary = vocabularies.active
            }
        case .waitingForMic, .decoding, .diarizing, .transcribing:
            restartJobID = jobID
            cancelCurrent.value = true
            flog("FileQueue: restarting \(job.url.lastPathComponent) as \(currentMode.rawValue)")
        case .saved, .savedToFallback, .empty, .failed, .cancelled:
            enqueue(urls: [job.url], mode: restartMode(for: job.mode), modelID: job.modelID)
        }
    }

    /// A call recording stays a call: its channels tell the speakers apart,
    /// and the dialog checkbox does not apply to it.
    private func restartMode(for mode: TranscriptMode) -> TranscriptMode {
        mode == .call ? .call : currentMode
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        if jobs.isEmpty { blockedDirectories = [] }
    }

    private func start() {
        guard runner == nil else { return }
        stopRequested = false
        abortRequested = false
        cancelCurrent.value = false
        isRunning = true
        runner = Task { [weak self] in
            await self?.run()
            self?.runner = nil
            self?.isRunning = false
            self?.stopRequested = false
            self?.abortRequested = false
            self?.cancelCurrent.value = false
        }
    }

    private func run() async {
        while let next = jobs.first(where: { $0.status == .pending }) {
            if stopRequested {
                flog("FileQueue: stop requested, \(jobs.count - finishedCount) job(s) left pending")
                return
            }
            await process(next.id)
            // A restart cancels only the job it targets. After a second Stop
            // the flag stays up and the loop ends on `stopRequested` anyway.
            if !abortRequested { cancelCurrent.value = false }
        }
    }

    /// Addressed by id rather than index throughout: the array can be mutated
    /// between awaits (a new drop appends, "Clear" removes finished rows), so a
    /// captured index would drift onto the wrong job.
    private func process(_ jobID: UUID) async {
        guard let job = self[jobID] else { return }
        let url = job.url
        let mode = job.mode
        let vocabulary = job.vocabulary
        let modelID = job.modelID
        update(jobID) { $0.startedAt = Date() }

        // Let the hotkey dictation flow finish before starting a new file.
        if micBusy.value {
            update(jobID) { $0.status = .waitingForMic }
            while micBusy.value, !cancelCurrent.value {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        if cancelCurrent.value {
            finishCancelled(jobID)
            return
        }

        guard modelManager.activeModel != nil else {
            finish(jobID, .failed, error: "test.noModel".localized)
            return
        }
        // A job can carry a model of its own; it may have been deleted since.
        if let modelID, !modelManager.models.contains(where: { $0.id == modelID && $0.isDownloaded }) {
            finish(jobID, .failed, error: "history.error.modelMissing".localized)
            return
        }
        if mode == .roles, let problem = diarizationProblem() {
            finish(jobID, .failed, error: problem)
            return
        }

        // Size guard before decoding — see `maxFileSize`.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        if size > Self.maxFileSize {
            finish(jobID, .failed,
                   error: AudioFileDecoder.DecoderError.fileTooLarge(url.lastPathComponent).localizedDescription)
            return
        }

        // What the source looked like as it was read: the transcribed list
        // compares against this to flag a file edited afterwards.
        let stamp = TranscriptRegistry.SourceStamp.read(url)

        if mode == .call {
            await processCall(jobID, url: url, stamp: stamp, vocabulary: vocabulary, modelID: modelID)
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

        // Decoding can't be interrupted, but there is no point starting whisper.
        if cancelCurrent.value {
            finishCancelled(jobID)
            return
        }

        let cancel = cancelCurrent
        let progress = progressHandler(for: jobID)

        // Diarization first: it takes seconds, and a missing model or helper
        // should surface before minutes of whisper rather than after.
        var speakers: [SpeakerSegment] = []
        if mode == .roles {
            update(jobID) { $0.status = .diarizing }
            do {
                speakers = try await DiarizationClient.diarize(
                    pcm: pcm,
                    modelsDirectory: diarizationModels.directory,
                    onProgress: progress,
                    shouldCancel: { cancel.value }
                )
            } catch is CancellationError {
                finishCancelled(jobID)
                return
            } catch {
                flog("FileQueue: diarization failed for \(url.lastPathComponent): \(error)")
                finish(jobID, .failed, error: error.localizedDescription)
                return
            }
        }

        update(jobID) {
            $0.status = .transcribing
            $0.progress = .none
        }

        let prompt = await fittedPrompt(for: vocabulary)

        let busy = micBusy
        let result: TimedTranscriptionResult
        do {
            result = try await engine.transcribeTimed(
                audioData: pcm,
                options: TranscriptionOptions(prompt: prompt, wordTimestamps: mode == .roles, modelID: modelID),
                onProgress: progress,
                shouldYield: { busy.value },
                shouldCancel: { cancel.value }
            )
        } catch is CancellationError {
            flog("FileQueue: transcription of \(url.lastPathComponent) interrupted")
            finishCancelled(jobID)
            return
        } catch {
            flog("FileQueue: transcribe failed for \(url.lastPathComponent): \(error)")
            finish(jobID, .failed, error: error.localizedDescription)
            return
        }

        let plainText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else {
            finish(jobID, .empty)
            return
        }
        let text: String
        if mode == .roles, !result.words.isEmpty {
            text = RolesFormatter.format(SpeakerTranscriptBuilder.build(words: result.words, segments: speakers))
        } else {
            text = plainText
        }
        update(jobID) { $0.text = text }
        save(jobID, text: text, url: url, mode: mode, stamp: stamp, vocabulary: vocabulary, modelID: modelID)
    }

    /// A call recording: the left channel is the user, the right one the app.
    ///
    /// The speech in each channel is found first (`SpeechSegmenter`), because
    /// that — not whisper's word times — is what gives the transcript its
    /// replies and their timestamps. Whisper is then handed the speech alone,
    /// with the silence taken out: it invents text on silence, and it would
    /// spend minutes on it either way. The other side is diarized when the
    /// models are there, to tell voices apart in a group call; without them it
    /// is one "Other", which is all a one-to-one call needs.
    private func processCall(_ jobID: UUID, url: URL, stamp: TranscriptRegistry.SourceStamp?,
                             vocabulary: Vocabulary?, modelID: String?) async {
        update(jobID) { $0.status = .decoding }
        // Decided here, on the main actor, so the decode can keep the channel
        // diarization needs and the file is never read twice.
        let canDiarize = diarizationProblem() == nil
        let sides: [CompactedAudio]
        let otherChannel: Data
        do {
            // Segmentation walks every sample of both channels — an hour of
            // call is 58 million per side — so it stays off the main actor with
            // the decoding.
            (sides, otherChannel) = try await Task.detached(priority: .utility) {
                let channels = try AudioFileDecoder.decodeChannels(url: url)
                let sides = [channels.left, channels.right].map {
                    CompactedAudio.make($0, spans: SpeechSegmenter.spans($0))
                }
                return (sides, canDiarize ? channels.right : Data())
            }.value
        } catch {
            flog("FileQueue: decode failed for call \(url.lastPathComponent): \(error)")
            finish(jobID, .failed, error: error.localizedDescription)
            return
        }
        if cancelCurrent.value {
            finishCancelled(jobID)
            return
        }
        flog("FileQueue: call \(url.lastPathComponent): "
             + sides.map { String(format: "%.0fs speech in %d span(s)", $0.duration, $0.spans.count) }
                 .joined(separator: ", "))

        // A channel with no speech is not sent anywhere: a muted microphone, a
        // denied system-audio permission, or simply a side that said nothing.
        let heard = sides.map { !$0.isEmpty }
        let cancel = cancelCurrent

        var speakers: [SpeakerSegment] = []
        if heard[1], canDiarize {
            update(jobID) { $0.status = .diarizing }
            do {
                // The original channel, not the compacted one: mapping segments
                // back would stretch a segment that crossed a separator over
                // the real silence between two replies, and the diarizer's
                // window holds only three voices — compaction would pack more
                // of them into it, exactly in the group call where it matters.
                speakers = try await DiarizationClient.diarize(
                    pcm: otherChannel,
                    modelsDirectory: diarizationModels.directory,
                    onProgress: progressHandler(for: jobID),
                    shouldCancel: { cancel.value }
                )
            } catch is CancellationError {
                finishCancelled(jobID)
                return
            } catch {
                flog("FileQueue: diarizing the other side of \(url.lastPathComponent) failed, keeping one voice: \(error)")
            }
        }

        update(jobID) {
            $0.status = .transcribing
            $0.progress = .none
        }
        let prompt = await fittedPrompt(for: vocabulary)
        let busy = micBusy
        let parts = heard.filter { $0 }.count
        var words: [[TimedWord]] = [[], []]
        var part = 0
        do {
            for (index, side) in sides.enumerated() where heard[index] {
                let spoken = try await engine.transcribeTimed(
                    audioData: side.pcm,
                    options: TranscriptionOptions(prompt: prompt, wordTimestamps: true,
                                                  modelID: modelID, suppressNonSpeech: true),
                    onProgress: progressHandler(for: jobID, part: part, of: parts),
                    shouldYield: { busy.value },
                    shouldCancel: { cancel.value }
                ).words
                // Compacted time back onto the recording's timeline.
                words[index] = side.place(spoken)
                part += 1
            }
        } catch is CancellationError {
            flog("FileQueue: transcription of call \(url.lastPathComponent) interrupted")
            finishCancelled(jobID)
            return
        } catch {
            flog("FileQueue: transcribe failed for call \(url.lastPathComponent): \(error)")
            finish(jobID, .failed, error: error.localizedDescription)
            return
        }

        let mine = EchoFilter.filter(me: words[0], other: words[1])
        let turns = CallTranscriptBuilder.turns(
            me: CallTranscriptBuilder.Channel(spans: sides[0].spans, words: mine),
            other: CallTranscriptBuilder.Channel(spans: sides[1].spans, words: words[1],
                                                 speakers: speakers)
        )
        guard !turns.isEmpty else {
            finish(jobID, .empty)
            return
        }
        let text = CallTranscriptBuilder.format(turns, call: callInfo?(url))
        update(jobID) { $0.text = text }
        save(jobID, text: text, url: url, mode: .call, stamp: stamp, vocabulary: vocabulary, modelID: modelID)
    }

    /// Chunk progress for one of `parts` equal-length runs of a job, so two
    /// channels fill one bar.
    private func progressHandler(for jobID: UUID, part: Int = 0, of parts: Int = 1) -> (Int, Int) -> Void {
        { [weak self] current, total in
            Task { @MainActor in
                self?.update(jobID) {
                    $0.progress = ChunkProgress(current: part * total + current, total: total * parts)
                }
            }
        }
    }

    /// The job's vocabulary as a whisper prompt, trimmed to what fits.
    private func fittedPrompt(for vocabulary: Vocabulary?) async -> String? {
        guard let terms = vocabulary?.terms, !terms.isEmpty else { return nil }
        let engine = self.engine
        do {
            let fitted = try await Task.detached(priority: .utility) {
                try engine.fitPrompt(terms: terms)
            }.value
            flog("FileQueue: vocabulary '\(vocabulary?.name ?? "")': \(fitted.used) of \(terms.count) terms fit the prompt")
            return fitted.prompt
        } catch {
            // Without the model there is nothing to transcribe either;
            // let transcribeTimed report that.
            flog("FileQueue: could not fit vocabulary prompt: \(error)")
            return nil
        }
    }

    private func save(_ jobID: UUID, text: String, url: URL, mode: TranscriptMode,
                      stamp: TranscriptRegistry.SourceStamp?, vocabulary: Vocabulary?,
                      modelID: String?) {
        do {
            let output = try TranscriptSaver.write(text: text,
                                                   audioName: url.lastPathComponent,
                                                   suffix: mode.fileSuffix,
                                                   into: destination(for: url))
            update(jobID) { $0.outputURL = output }
            finish(jobID, .saved)
            remember(url, mode: mode, output: output, stamp: stamp, vocabulary: vocabulary, modelID: modelID)
        } catch {
            flog("FileQueue: save failed for \(url.lastPathComponent): \(error)")
            // Don't lose a transcript that cost minutes to produce. Application
            // Support is never TCC-gated, and unlike keeping the text in memory
            // this survives quitting the app.
            do {
                let output = try TranscriptSaver.write(text: text,
                                                       audioName: url.lastPathComponent,
                                                       suffix: mode.fileSuffix,
                                                       into: TranscriptSaver.fallbackDirectory)
                update(jobID) { $0.outputURL = output }
                finish(jobID, .savedToFallback)
                remember(url, mode: mode, output: output, stamp: stamp, vocabulary: vocabulary, modelID: modelID)
            } catch {
                finish(jobID, .failed, error: error.localizedDescription)
            }
        }
    }

    /// Why dialog mode cannot run right now, if it cannot.
    private func diarizationProblem() -> String? {
        if !DiarizationClient.isSupportedSystem {
            return DiarizationClient.DiarizationError.unsupportedSystem.localizedDescription
        }
        if DiarizationClient.helperURL == nil {
            return DiarizationClient.DiarizationError.helperMissing.localizedDescription
        }
        if !diarizationModels.isInstalled {
            return DiarizationClient.DiarizationError.modelsMissing.localizedDescription
        }
        return nil
    }

    private func remember(_ url: URL, mode: TranscriptMode, output: URL,
                          stamp: TranscriptRegistry.SourceStamp?, vocabulary: Vocabulary?,
                          modelID: String?) {
        guard let stamp else { return }
        registry.add(source: url, mode: mode, output: output, stamp: stamp,
                     dictionaryName: vocabulary?.name,
                     modelID: modelID ?? modelManager.activeModel?.id)
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

    /// A cancelled job that `stopAndRestart` asked for comes back as a fresh
    /// pending job in the same place, with the settings in force now.
    private func finishCancelled(_ jobID: UUID) {
        guard restartJobID == jobID,
              let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            finish(jobID, .cancelled)
            return
        }
        restartJobID = nil
        let url = jobs[index].url
        jobs[index] = Job(url: url, mode: restartMode(for: jobs[index].mode),
                          vocabulary: vocabularies.active, modelID: jobs[index].modelID)
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
                                                       suffix: job.mode.fileSuffix,
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
            .deletingPathExtension + jobs[index].mode.fileSuffix + ".txt"
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
