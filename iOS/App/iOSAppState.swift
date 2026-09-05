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
    private var ipcWatchdogTimer: DispatchSourceTimer?
    private var keyboardActive = false

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
        // The keyboard cannot launch us, so its presence signal doubles as a liveness probe:
        // if this ever arrives, the host survived in the background as intended.
        ipcServer.onKeyboardPresenceChanged = { [weak self] active in
            Task { @MainActor in
                BackgroundKeepAliveService.shared.setKeyboardActive(active)
                self?.setKeyboardActive(active)
            }
        }
        ipcServer.start()
        ipcServerRunning = true

        // Touch the keep-alive service early: it restores the persisted background mode
        // on launch, so the user never has to find the toggle again.
        Task { @MainActor in
            BackgroundKeepAliveService.shared.onKeyboardBecameActive = { [weak self] in
                self?.ensureModelLoadedInBackground()
            }
            _ = BackgroundKeepAliveService.shared.isEnabled
        }

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
            // Re-arm both keep-alive layers. Simply opening the app is now enough to
            // recover background mode after another app stole the PiP window.
            Task { @MainActor in
                BackgroundKeepAliveService.shared.revive(reason: "didBecomeActive")
                PiPService.shared.reassertIfNeeded()
            }
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

        // Keep the IPC watchdog running for as long as background mode is on.
        // It used to be tied to isPiPActive, which meant the watchdog died exactly when
        // another app stole PiP — the moment it was needed most.
        // Using DispatchQueue.main.async since we're in init() and need to defer MainActor access
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            BackgroundKeepAliveService.shared.$isEnabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enabled in
                    if enabled {
                        self?.startIPCWatchdogTimer()
                    } else {
                        self?.stopIPCWatchdogTimer()
                    }
                }
                .store(in: &self.cancellables)
        }
    }

    /// While background mode is on, periodically ensure the IPC server is running.
    ///
    /// The 5s cadence is NOT tunable: `IPCServer.ensureRunning()` treats a gap over 10s
    /// between calls as evidence of suspension and force-restarts the listener. Anything
    /// slower turns that heuristic into a permanent teardown/rebuild loop, which leaves
    /// the socket down ~1s on every tick and makes the keyboard fail to connect.
    private func startIPCWatchdogTimer() {
        stopIPCWatchdogTimer()
        flog("App: starting IPC watchdog timer (5s)")

        let timer = DispatchSource.makeTimerSource(flags: [], queue: .main)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.ipcServer.ensureRunning()
        }
        timer.resume()
        ipcWatchdogTimer = timer
    }

    private func stopIPCWatchdogTimer() {
        guard ipcWatchdogTimer != nil else { return }
        flog("App: stopping IPC watchdog timer")
        ipcWatchdogTimer?.cancel()
        ipcWatchdogTimer = nil
    }

    /// Keyboard opened/closed: keep the model hot while it is on screen.
    @MainActor
    private func setKeyboardActive(_ active: Bool) {
        guard keyboardActive != active else { return }
        keyboardActive = active
        if active {
            ensureModelLoadedInBackground()
        }
    }

    private func ensureModelLoadedInBackground() {
        guard transcriptionEngine.isModelLoaded == false, modelManager.activeModel != nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcriptionEngine.ensureModelLoaded()
        }
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
            sessionManager.state = .error("error.modelNotLoaded".localized)
            return
        }
        sessionManager.state = .recording
        sessionManager.recordingStartTime = Date()
        _ = audioCaptureService.startCapture()
    }

    func transcribeFile(url: URL) {
        guard sessionManager.state == .idle else { return }
        guard modelManager.activeModel != nil else {
            sessionManager.state = .error("error.modelNotLoaded".localized)
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
