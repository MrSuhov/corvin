import AppKit

/// Runs one push-to-talk dictation, from key down to text in the target app.
///
/// Owns the `SessionState` transitions of the hotkey flow and the lifetime of
/// the session's recognizer. What happens to the transcript afterwards —
/// insertion, clipboard, history — belongs to the pipeline's sinks.
///
/// Every method is called on the main thread.
final class DictationCoordinator {
    private let sessionManager: SessionManager
    private let modelManager: ModelManager
    private let historyStore: HistoryStore
    private let audioCapture: AudioCaptureService
    private let accessibility: AccessibilityService
    private let engine: TranscriptionEngine

    private var recognizer: SpeechRecognizer?
    private var pipeline: TranscriptPipeline?
    private var eventsTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var recordingStoppedAt: Date?

    init(sessionManager: SessionManager,
         modelManager: ModelManager,
         historyStore: HistoryStore,
         audioCapture: AudioCaptureService,
         accessibility: AccessibilityService,
         engine: TranscriptionEngine) {
        self.sessionManager = sessionManager
        self.modelManager = modelManager
        self.historyStore = historyStore
        self.audioCapture = audioCapture
        self.accessibility = accessibility
        self.engine = engine
    }

    func keyDown() {
        flog("startRecording: current state=\(sessionManager.state)")
        switch sessionManager.state {
        case .idle: break
        case .error, .done: sessionManager.state = .idle
        default:
            flog("startRecording: rejected, state=\(sessionManager.state)")
            return
        }

        guard audioCapture.hasMicrophonePermission else {
            flog("startRecording: no mic permission, requesting")
            audioCapture.requestMicrophonePermission { granted in
                flog("startRecording: mic permission granted=\(granted)")
                if granted {
                    DispatchQueue.main.async { self.keyDown() }
                }
            }
            return
        }

        let processors: [TranscriptProcessor] = []
        let realtime = DictationSettings.isRealtimeEnabled
            && UserDefaults.standard.bool(forKey: "autoInsertText")
            && !processors.contains { $0.modifiesText }
        guard let recognizer = makeRecognizer(realtime: realtime) else {
            flog("startRecording: no active model")
            sessionManager.state = .error("error.modelNotLoaded".localized)
            return
        }
        let pipeline = makePipeline(processors: processors, modelUsed: recognizer.displayName, realtime: realtime)
        self.recognizer = recognizer
        self.pipeline = pipeline
        recordingStoppedAt = nil

        eventsTask = Task {
            for await event in recognizer.events {
                await MainActor.run { pipeline.send(event) }
            }
        }

        flog("startRecording: starting capture, recognizer=\(type(of: recognizer)) (\(recognizer.displayName))")
        sessionManager.state = .recording
        sessionManager.recordingStartTime = Date()
        audioCapture.onSamples = { samples in recognizer.append(samples) }
        audioCapture.startCapture()

        // Kept so key up can wait for it: a quick tap must not finish a
        // recognizer whose start has not completed yet.
        let startTask = Task { try await recognizer.start() }
        self.startTask = startTask
        Task {
            do {
                try await startTask.value
            } catch {
                flog("startRecording: recognizer failed to start: \(error)")
                await MainActor.run { self.abort(recognizer, message: error.localizedDescription) }
            }
        }
    }

    func keyUp() {
        flog("stopRecordingAndTranscribe: current state=\(sessionManager.state)")
        guard sessionManager.state == .recording, let recognizer, let pipeline else {
            flog("stopRecordingAndTranscribe: rejected, not recording")
            return
        }

        _ = audioCapture.stopCapture()
        recordingStoppedAt = Date()
        sessionManager.state = .transcribing
        let eventsTask = self.eventsTask
        let startTask = self.startTask

        Task {
            do {
                flog("transcribe: starting")
                try await startTask?.value
                let raw = try await recognizer.finish()
                // Every committed chunk reaches the sinks before `.finished` does.
                await eventsTask?.value
                let result = try await pipeline.process(raw)
                flog("transcribe: result text='\(result.text.prefix(100))', lang=\(result.language)")
                await MainActor.run { self.complete(with: result, pipeline: pipeline) }
            } catch {
                flog("transcribe: ERROR \(error)")
                await MainActor.run {
                    self.endSession()
                    self.showError(error.localizedDescription, resetAfter: 3)
                }
            }
        }
    }

    // MARK: - Private

    /// Nil when no model has been chosen.
    private func makeRecognizer(realtime: Bool) -> SpeechRecognizer? {
        guard let model = modelManager.activeModel else { return nil }
        return realtime
            ? WhisperStreamingRecognizer(engine: engine, displayName: model.name)
            : WhisperBatchRecognizer(engine: engine, displayName: model.name)
    }

    private func makePipeline(processors: [TranscriptProcessor], modelUsed: String, realtime: Bool) -> TranscriptPipeline {
        let defaults = UserDefaults.standard
        let autoInsert = defaults.bool(forKey: "autoInsertText")
        let copyToClipboard = defaults.bool(forKey: "copyToClipboard")
        flog("insertion: autoInsert=\(autoInsert), copyToClipboard=\(copyToClipboard), realtime=\(realtime)")

        var sinks: [TranscriptSink] = []
        if autoInsert {
            sinks.append(TextInsertionSink(accessibility: accessibility, mode: realtime ? .asCommitted : .onRelease))
        }
        if copyToClipboard {
            sinks.append(ClipboardSink())
        }
        sinks.append(HistorySink(store: historyStore, modelUsed: modelUsed) { [weak self] in
            guard let self, let start = self.sessionManager.recordingStartTime else { return 0 }
            return (self.recordingStoppedAt ?? Date()).timeIntervalSince(start)
        })
        return TranscriptPipeline(processors: processors, sinks: sinks)
    }

    private func complete(with result: TranscriptionResult, pipeline: TranscriptPipeline) {
        endSession()
        guard !result.text.isEmpty else {
            flog("transcribe: empty result, showing error feedback")
            showError("error.recognitionFailed".localized, resetAfter: 2.5)
            return
        }

        sessionManager.state = .inserting(result.text)
        pipeline.send(.finished(result))
        sessionManager.state = .done(result.text)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if case .done = self.sessionManager.state {
                self.sessionManager.state = .idle
            }
        }
    }

    /// Tears down a session whose recognizer could not start. Ignored when the
    /// session has already moved on — the user released the key and a newer
    /// session may be running.
    private func abort(_ failed: SpeechRecognizer, message: String) {
        guard recognizer === failed else { return }
        if sessionManager.state == .recording {
            _ = audioCapture.stopCapture()
        }
        failed.cancel()
        endSession()
        showError(message, resetAfter: 3)
    }

    private func endSession() {
        recognizer = nil
        pipeline = nil
        eventsTask = nil
        startTask = nil
    }

    private func showError(_ message: String, resetAfter delay: TimeInterval) {
        sessionManager.state = .error(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if case .error = self.sessionManager.state {
                self.sessionManager.state = .idle
            }
        }
    }
}
