import SwiftUI
import Combine
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.corvin.app", category: "state")

class iOSAppState: ObservableObject {
    let sessionManager = SessionManager()
    let modelManager = ModelManager()
    let historyStore = HistoryStore()

    private var transcriptionEngine: TranscriptionEngine!
    private var ipcServer: IPCServer!
    private var audioCaptureService: AudioCaptureService!
    private var cancellables = Set<AnyCancellable>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pipKeepAliveTimer: DispatchSourceTimer?

    @Published var onboardingCompleted: Bool {
        didSet {
            let defaults: UserDefaults
            #if os(iOS)
            defaults = UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
            #else
            defaults = .standard
            #endif
            defaults.set(onboardingCompleted, forKey: "onboardingCompleted")
        }
    }

    @Published var ipcServerRunning = false

    init() {
        #if os(iOS)
        let defaults = UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        let defaults = UserDefaults.standard
        #endif

        defaults.register(defaults: [
            "autoCleanupPeriod": "never",
            "pttLongPressThreshold": 0.5,
        ])

        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")

        transcriptionEngine = TranscriptionEngine(modelManager: modelManager)
        audioCaptureService = AudioCaptureService()
        audioCaptureService.prepareEngine()

        let transcriptionService = TranscriptionService(engine: transcriptionEngine)
        ipcServer = IPCServer(transcriptionService: transcriptionService, audioCaptureService: audioCaptureService)
        ipcServer.start()
        ipcServerRunning = true

        // Warm up model
        if modelManager.activeModel != nil {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.transcriptionEngine.warmup()
            }
        }

        // Keep IPC server alive when app goes to background
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            flog("App: didEnterBackground")
            self?.beginBackgroundKeepAlive()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            flog("App: willEnterForeground")
            self?.endBackgroundKeepAlive()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            flog("App: didBecomeActive, modelLoaded=\(self?.transcriptionEngine.isModelLoaded ?? false)")
            // Force restart IPC server - it may be in "zombie" state after background
            self?.ipcServer.forceRestart()
            // Reload model if it was evicted from memory
            if self?.transcriptionEngine.isModelLoaded == false && self?.modelManager.activeModel != nil {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.transcriptionEngine.ensureModelLoaded()
                }
            }
        }

        // On memory warning, unload model to avoid crash — it will be reloaded on didBecomeActive
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            flog("App: didReceiveMemoryWarning, unloading model")
            self?.transcriptionEngine.unloadModel()
        }

        // Subscribe to PiP wake-from-suspension notifications
        // This handles the case when app wakes via PiP but user doesn't open the app
        NotificationCenter.default.addObserver(
            forName: .pipWokeFromSuspension,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            flog("App: received pipWokeFromSuspension notification, modelLoaded=\(self?.transcriptionEngine.isModelLoaded ?? false)")
            self?.ipcServer.forceRestart()
            // Reload model if evicted during suspension
            if self?.transcriptionEngine.isModelLoaded == false && self?.modelManager.activeModel != nil {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.transcriptionEngine.ensureModelLoaded()
                }
            }
        }

        // Subscribe to PiP state changes to start/stop keep-alive timer
        // Using DispatchQueue.main.async since we're in init() and need to defer MainActor access
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            PiPService.shared.$isPiPActive
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isPiPActive in
                    if isPiPActive {
                        self?.startPiPKeepAliveTimer()
                    } else {
                        self?.stopPiPKeepAliveTimer()
                    }
                }
                .store(in: &self.cancellables)
        }
    }

    /// When PiP is active, periodically ensure IPC server is running
    private func startPiPKeepAliveTimer() {
        guard pipKeepAliveTimer == nil else { return }
        flog("App: starting PiP keep-alive timer")

        let timer = DispatchSource.makeTimerSource(flags: [], queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.ipcServer.ensureRunning()
        }
        timer.resume()
        pipKeepAliveTimer = timer
    }

    private func stopPiPKeepAliveTimer() {
        guard pipKeepAliveTimer != nil else { return }
        flog("App: stopping PiP keep-alive timer")
        pipKeepAliveTimer?.cancel()
        pipKeepAliveTimer = nil
    }

    private func beginBackgroundKeepAlive() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "IPC KeepAlive") { [weak self] in
            self?.endBackgroundKeepAlive()
        }
    }

    private func endBackgroundKeepAlive() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // For in-app PTT test
    func startRecording() {
        guard sessionManager.state == .idle || sessionManager.state != .recording else { return }
        guard modelManager.activeModel != nil else {
            sessionManager.state = .error("Модель не загружена")
            return
        }
        sessionManager.state = .recording
        sessionManager.recordingStartTime = Date()
        _ = audioCaptureService.startCapture()
    }

    func transcribeFile(url: URL) {
        guard sessionManager.state == .idle else { return }
        guard modelManager.activeModel != nil else {
            sessionManager.state = .error("Модель не загружена")
            return
        }

        sessionManager.state = .transcribing

        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let pcmData = try AudioFileDecoder.decode(url: url)
                let result = try await transcriptionEngine.transcribe(audioData: pcmData)
                await MainActor.run {
                    guard !result.text.isEmpty else {
                        sessionManager.state = .idle
                        return
                    }
                    UIPasteboard.general.string = result.text
                    sessionManager.state = .done(result.text)

                    historyStore.addRecord(
                        text: result.text,
                        duration: 0,
                        modelUsed: modelManager.activeModel?.name ?? "unknown",
                        language: result.language
                    )

                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        if case .done = self?.sessionManager.state {
                            self?.sessionManager.state = .idle
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    sessionManager.state = .error(error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        if case .error = self?.sessionManager.state {
                            self?.sessionManager.state = .idle
                        }
                    }
                }
            }
        }
    }

    func stopRecordingAndTranscribe() {
        guard sessionManager.state == .recording else { return }
        let audioData = audioCaptureService.stopCapture()
        sessionManager.state = .transcribing

        Task {
            do {
                let result = try await transcriptionEngine.transcribe(audioData: audioData)
                await MainActor.run {
                    guard !result.text.isEmpty else {
                        sessionManager.state = .idle
                        return
                    }
                    sessionManager.state = .done(result.text)

                    let duration = sessionManager.recordingStartTime.map {
                        Date().timeIntervalSince($0)
                    } ?? 0

                    historyStore.addRecord(
                        text: result.text,
                        duration: duration,
                        modelUsed: modelManager.activeModel?.name ?? "unknown",
                        language: result.language
                    )

                    #if os(iOS)
                    UIPasteboard.general.string = result.text
                    #endif

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        if case .done = self?.sessionManager.state {
                            self?.sessionManager.state = .idle
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    sessionManager.state = .error(error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        if case .error = self?.sessionManager.state {
                            self?.sessionManager.state = .idle
                        }
                    }
                }
            }
        }
    }
}
