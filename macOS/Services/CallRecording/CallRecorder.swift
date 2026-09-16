import AppKit
import AVFoundation
import Combine

/// Records a call: the microphone as the user's side, a chosen app's audio as
/// the other side, into one two-channel file. Once the call ends the file is
/// converted to AAC and handed to `FileTranscriptionQueue` as a `.call` job,
/// which writes the script.
///
/// Deliberately not part of `SessionState`. A session that is not idle parks
/// the file queue and blocks hotkey dictation; a call lasts an hour, and the
/// user should still be able to dictate a note while it records.
@MainActor
final class CallRecorder: ObservableObject {

    enum State: Equatable {
        case idle
        case starting(CallApp)
        case recording(CallApp, since: Date)
        case finishing(CallApp)
        case failed(LocalizedMessage)
    }

    struct Levels: Equatable {
        var me: Float = 0
        var other: Float = 0
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var levels = Levels()
    /// Recording goes on, but something is likely wrong, such as no sound
    /// arriving from the app.
    @Published private(set) var warning: LocalizedMessage?

    static let lastAppKey = "callRecording.lastBundleID"
    /// Shorter recordings are an accidental click, not a call.
    nonisolated static let minimumDuration: TimeInterval = 1
    /// How long a start failure stays on screen.
    private static let failureDisplay: TimeInterval = 6

    /// Another app's audio needs ScreenCaptureKit (13) or a process tap (14.2).
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    var lastBundleID: String? { UserDefaults.standard.string(forKey: Self.lastAppKey) }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private let fileQueue: FileTranscriptionQueue
    private var sources: [CallAudioSource] = []
    private var writer: CallTimelineWriter?
    private var levelTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var failureReset: DispatchWorkItem?
    /// A source that died while the other one was still starting: `stop()`
    /// only works from `.recording`, so the start path has to see it.
    private var endedDuringStart: LocalizedMessage?

    init(fileQueue: FileTranscriptionQueue) {
        self.fileQueue = fileQueue
        recoverInterruptedRecordings()
    }

    // MARK: - Control

    func start(app: CallApp) {
        switch state {
        case .idle, .failed: break
        case .starting, .recording, .finishing: return
        }
        guard #available(macOS 13.0, *) else { return }
        failureReset?.cancel()
        warning = nil
        endedDuringStart = nil
        state = .starting(app)
        Task { await begin(app) }
    }

    /// Stop and hand the recording to the transcription queue.
    func stop() {
        guard case .recording(let app, _) = state, let writer else { return }
        state = .finishing(app)
        stopCapture()
        self.writer = nil

        let preferred = fileQueue.outputDirectory ?? Self.defaultCallsDirectory
        Task {
            let duration = await Task.detached(priority: .userInitiated) { writer.finish() }.value
            let parts = writer.parts
            guard duration >= Self.minimumDuration else {
                flog("CallRecorder: \(duration)s is too short to keep")
                for part in parts { try? FileManager.default.removeItem(at: part) }
                finishIdle()
                return
            }
            let outputs = await Task.detached(priority: .userInitiated) {
                Self.finalize(parts, preferredDirectory: preferred)
            }.value
            for output in outputs { fileQueue.enqueueCall(output) }
            finishIdle()
        }
    }

    /// Quitting mid-call: close the part in flight so the next launch can
    /// merge and transcribe the call.
    func finishForTermination() {
        guard let writer else { return }
        stopCapture()
        _ = writer.finish()
        self.writer = nil
    }

    nonisolated static func openSystemAudioSettings() {
        let anchor: String
        if #available(macOS 14.2, *) {
            anchor = "Privacy_AudioCapture"
        } else {
            anchor = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recording

    @available(macOS 13.0, *)
    private func begin(_ app: CallApp) async {
        // Unique, because names go down to the minute: a recording started
        // right after a crash must not land on the parts that
        // `recoverInterruptedRecordings` is still merging.
        let base = Self.uniqueBase(in: Self.recordingsDirectory, base: Self.baseName(for: app, at: Date()))
        do {
            let writer = try CallTimelineWriter(directory: Self.recordingsDirectory, base: base,
                                                chunkDuration: CallSettings.chunkDuration)
            self.writer = writer

            let mic = MicSource()
            let remote: CallAudioSource
            if #available(macOS 14.2, *) {
                remote = ProcessTapSource(app: app)
            } else {
                remote = ScreenCaptureSource(app: app)
            }
            mic.onChunk = { samples, hostTime in writer.append(samples, hostTime: hostTime, channel: .me) }
            remote.onChunk = { samples, hostTime in writer.append(samples, hostTime: hostTime, channel: .other) }
            for source in [mic, remote] as [CallAudioSource] {
                source.onWarning = { [weak self] message in
                    Task { @MainActor in self?.warning = message }
                }
                source.onEnded = { [weak self] message in
                    Task { @MainActor in
                        guard let self else { return }
                        flog("CallRecorder: a source ended (\(message.key))")
                        if case .starting = self.state {
                            self.endedDuringStart = message
                            return
                        }
                        self.stop()
                    }
                }
            }
            sources = [mic, remote]

            try await mic.start()
            try await remote.start()
        } catch {
            flog("CallRecorder: start failed: \(error)")
            abandonRecording()
            fail((error as? CallRecordingError)?.message
                 ?? LocalizedMessage("call.error.captureFailed", error.localizedDescription))
            return
        }

        if let message = endedDuringStart {
            endedDuringStart = nil
            abandonRecording()
            fail(message)
            return
        }

        UserDefaults.standard.set(app.bundleID, forKey: Self.lastAppKey)
        state = .recording(app, since: Date())
        flog("CallRecorder: recording \(app.bundleID) into \(base), parts of \(CallSettings.chunkDuration)s")
        observeTermination(of: app)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLevels() }
        }
    }

    /// The app quitting ends the call.
    private func observeTermination(of app: CallApp) {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard quit?.bundleIdentifier == app.bundleID,
                  NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
            else { return }
            Task { @MainActor in
                flog("CallRecorder: \(app.bundleID) quit, saving")
                self?.stop()
            }
        }
    }

    private func refreshLevels() {
        guard let writer else { return }
        // A disk that stopped taking writes: keep what was recorded rather
        // than going on into nothing. The transcript of the saved part is the
        // lasting signal; the warning only shows while it is being saved.
        if writer.hasFailed {
            flog("CallRecorder: the recording file could not be written, stopping")
            warning = LocalizedMessage("call.warning.writeFailed")
            stop()
            return
        }
        let current = writer.levels
        levels = Levels(me: current.me, other: current.other)
    }

    private func stopCapture() {
        sources.forEach { $0.stop() }
        sources = []
        levelTimer?.invalidate()
        levelTimer = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    private func abandonRecording() {
        stopCapture()
        let parts = writer?.parts ?? []
        _ = writer?.finish()
        writer = nil
        for part in parts { try? FileManager.default.removeItem(at: part) }
    }

    private func fail(_ message: LocalizedMessage) {
        state = .failed(message)
        let reset = DispatchWorkItem { [weak self] in
            guard let self, case .failed = self.state else { return }
            self.state = .idle
        }
        failureReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.failureDisplay, execute: reset)
    }

    private func finishIdle() {
        state = .idle
        warning = nil
        levels = Levels()
    }

    // MARK: - Files

    /// Recordings in progress. Anything left here at launch is a call that was
    /// cut off by a quit or a crash.
    nonisolated static var recordingsDirectory: URL {
        applicationSupport.appendingPathComponent("Corvin/Recordings", isDirectory: true)
    }

    nonisolated static var defaultCallsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Corvin/Calls", isDirectory: true)
    }

    /// Never TCC-gated, like `TranscriptSaver.fallbackDirectory`.
    nonisolated static var fallbackCallsDirectory: URL {
        applicationSupport.appendingPathComponent("Corvin/Calls", isDirectory: true)
    }

    private nonisolated static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    static func baseName(for app: CallApp, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let name = "call.fileName".localized(with: app.name, formatter.string(from: date))
        return name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
    }

    /// The recording's parts merged into one AAC `.m4a` in the calls folder,
    /// with the PCM parts removed.
    ///
    /// Returns what to transcribe: one merged file, or — if no folder would
    /// take the merge — the parts themselves, moved out of `Recordings` so a
    /// later launch does not recover them again. Each of those is transcribed
    /// on its own, which is worse than one script but loses nothing.
    nonisolated static func finalize(_ parts: [URL], preferredDirectory: URL) -> [URL] {
        guard let first = parts.first else { return [] }
        let base = CallRecordingParts.base(of: first)
        for directory in [preferredDirectory, fallbackCallsDirectory] {
            let target = uniqueURL(in: directory, base: base, pathExtension: "m4a")
            // Merged under a temporary name and renamed: quitting midway would
            // otherwise leave an unreadable .m4a in the calls folder, with no
            // index and nothing to say it is broken.
            let partial = directory.appendingPathComponent(".\(target.lastPathComponent).partial")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: partial)
                try merge(parts, to: partial)
                try FileManager.default.moveItem(at: partial, to: target)
                for part in parts { try? FileManager.default.removeItem(at: part) }
                flog("CallRecorder: saved \(target.path) from \(parts.count) part(s)")
                return [target]
            } catch {
                flog("CallRecorder: could not save into \(directory.path): \(error)")
                try? FileManager.default.removeItem(at: partial)
            }
        }
        return parts.map { part in
            let target = uniqueURL(in: fallbackCallsDirectory,
                                   base: part.deletingPathExtension().lastPathComponent,
                                   pathExtension: CallRecordingParts.pathExtension)
            do {
                try FileManager.default.createDirectory(at: fallbackCallsDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: part, to: target)
                return target
            } catch {
                flog("CallRecorder: could not move \(part.lastPathComponent): \(error)")
                return part
            }
        }
    }

    /// The parts, in order, as one AAC file. Their format is the writer's, so
    /// they concatenate sample for sample; a part that cannot be read is
    /// skipped rather than losing the whole call.
    nonisolated static func merge(_ sources: [URL], to target: URL) throws {
        guard let first = sources.first else {
            throw CallRecordingError.captureFailed("nothing to merge")
        }
        let format = try AVAudioFile(forReading: first).processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48000,
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: target, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            // Not every bit rate is valid for every rate and channel count;
            // let the encoder pick.
            settings.removeValue(forKey: AVEncoderBitRateKey)
            try? FileManager.default.removeItem(at: target)
            output = try AVAudioFile(forWriting: target, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000) else {
            throw CallRecordingError.captureFailed("cannot allocate a conversion buffer")
        }
        var written: AVAudioFramePosition = 0
        for source in sources {
            guard let input = try? AVAudioFile(forReading: source),
                  input.processingFormat.sampleRate == format.sampleRate,
                  input.processingFormat.channelCount == format.channelCount
            else {
                flog("CallRecorder: skipping unreadable part \(source.lastPathComponent)")
                continue
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
        }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: target)
            throw CallRecordingError.captureFailed("every part was unreadable")
        }
    }

    /// A base name whose first part file does not exist yet.
    nonisolated static func uniqueBase(in directory: URL, base: String) -> String {
        var candidate = base
        var index = 1
        while FileManager.default.fileExists(atPath: CallRecordingParts.url(in: directory, base: candidate, index: 1).path) {
            candidate = "\(base)_\(index)"
            index += 1
        }
        return candidate
    }

    nonisolated static func uniqueURL(in directory: URL, base: String, pathExtension: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(pathExtension)")
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(index).\(pathExtension)")
            index += 1
        }
        return candidate
    }

    /// PCM CAF stays readable after a crash, so a call cut off mid-recording
    /// is merged now and transcribed like any other. Parts of one call are
    /// grouped by name, so a crash costs only the seconds that never reached
    /// the part in flight.
    private func recoverInterruptedRecordings() {
        let listing = (try? FileManager.default.contentsOfDirectory(at: Self.recordingsDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        let recordings = CallRecordingParts.group(listing)
        guard !recordings.isEmpty else { return }

        let preferred = fileQueue.outputDirectory ?? Self.defaultCallsDirectory
        Task {
            for recording in recordings {
                let parts = recording.parts
                let outputs = await Task.detached(priority: .utility) { () -> [URL] in
                    let frames = parts.reduce(AVAudioFramePosition(0)) { total, part in
                        total + ((try? AVAudioFile(forReading: part))?.length ?? 0)
                    }
                    guard Double(frames) >= CallTimelineWriter.sampleRate * Self.minimumDuration else {
                        for part in parts { try? FileManager.default.removeItem(at: part) }
                        return []
                    }
                    return Self.finalize(parts, preferredDirectory: preferred)
                }.value
                flog("CallRecorder: recovered \(recording.base) (\(parts.count) part(s)) as \(outputs.map(\.lastPathComponent))")
                for output in outputs { fileQueue.enqueueCall(output) }
            }
        }
    }
}
