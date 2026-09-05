import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    let sessionManager = SessionManager()
    let modelManager = ModelManager()
    let historyStore = HistoryStore()

    private var hotkeyService: HotkeyService!
    private var audioCaptureService: AudioCaptureService!
    private var accessibilityService: AccessibilityService!
    private var layoutSwitchService: LayoutSwitchService!
    private(set) var transcriptionEngine: TranscriptionEngine!
    private(set) var fileQueue: FileTranscriptionQueue!

    private var statusBarController: StatusBarController!
    private var floatingIndicator: FloatingIndicatorController!
    private var updaterService: UpdaterService!

    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    let settingsTabSelection = SettingsTabSelection()
    private var historyWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// AppKit delivers the open-documents Apple Event from inside
    /// `finishLaunching`, i.e. *before* `applicationDidFinishLaunching` has
    /// built any of the services below. Launching Corvin by double-clicking an
    /// audio file therefore has to park the URLs until we are ready for them.
    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        flog("=== applicationDidFinishLaunching ===")

        // Kill other running instances of Corvin (allows drag-replace from DMG)
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") {
            if app.processIdentifier != myPID {
                app.terminate()
            }
        }

        UserDefaults.standard.register(defaults: [
            "autoInsertText": true,
            "copyToClipboard": false,
            "indicatorEnabled": true,
            "indicatorPosition": "bottomCenter",
            "indicatorSize": "normal",
            "autoCleanupPeriod": "never",
            "layoutSwitchEnabled": true,
            "layoutSwitchChangesInputSource": true,
            "layoutSwitchKeyCode": ModifierKey.option.canonicalKeyCode,
        ])

        accessibilityService = AccessibilityService()
        layoutSwitchService = LayoutSwitchService(accessibility: accessibilityService)
        audioCaptureService = AudioCaptureService()
        transcriptionEngine = TranscriptionEngine(modelManager: modelManager)
        // App-lifetime owner: the settings pane that drives this queue is torn
        // down whenever the user switches tabs or the interface language, so a
        // view-owned queue would die mid-batch.
        fileQueue = FileTranscriptionQueue(engine: transcriptionEngine,
                                          sessionManager: sessionManager,
                                          modelManager: modelManager)
        hotkeyService = HotkeyService()

        statusBarController = StatusBarController(
            sessionManager: sessionManager,
            modelManager: modelManager,
            historyStore: historyStore,
            appDelegate: self
        )

        floatingIndicator = FloatingIndicatorController(sessionManager: sessionManager)

        // Start Sparkle: begins the background update schedule and backs the
        // "Check for Updates…" menu item.
        updaterService = UpdaterService.shared
        flog("updater started")

        setupBindings()
        hotkeyService.start()
        flog("hotkeyService started")

        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            flog("showing onboarding")
            showOnboarding()
        }

        // Preload model + warm up Metal shaders so first transcription is instant
        if modelManager.activeModel != nil {
            flog("warmup: starting for model \(modelManager.activeModel!.name)")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.transcriptionEngine.warmup()
                self?.transcriptionEngine.startKeepAlive()
                flog("warmup: completed, keepAlive started")
            }
        } else {
            flog("warmup: skipped, no active model")
        }

        // Reload model when Mac wakes from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            flog("App: didWake, modelLoaded=\(self?.transcriptionEngine.isModelLoaded ?? false)")
            if self?.transcriptionEngine.isModelLoaded == false && self?.modelManager.activeModel != nil {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.transcriptionEngine.ensureModelLoaded()
                    self?.transcriptionEngine.startKeepAlive()
                }
            }
        }

        didFinishLaunching = true
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            openFiles(urls)
        }
    }

    private func setupBindings() {
        hotkeyService.onKeyDown = { [weak self] in
            self?.startRecording()
        }

        hotkeyService.onKeyUp = { [weak self] in
            self?.stopRecordingAndTranscribe()
        }

        hotkeyService.onLayoutSwitchTap = { [weak self] in
            self?.layoutSwitchService.convertTextAtCursor()
        }

        sessionManager.$state
            .sink { [weak self] state in
                self?.statusBarController.updateState(state)
                self?.floatingIndicator.updateState(state)
            }
            .store(in: &cancellables)

        // Toggling layout switching changes which event types the tap must
        // observe, so the tap is rebuilt when the setting changes.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.hotkeyService.refreshEventMask()
        }
    }

    private func startRecording() {
        flog("startRecording: current state=\(sessionManager.state)")
        switch sessionManager.state {
        case .idle: break
        case .error, .done: sessionManager.state = .idle
        default:
            flog("startRecording: rejected, state=\(sessionManager.state)")
            return
        }

        guard audioCaptureService.hasMicrophonePermission else {
            flog("startRecording: no mic permission, requesting")
            audioCaptureService.requestMicrophonePermission { granted in
                flog("startRecording: mic permission granted=\(granted)")
                if granted {
                    DispatchQueue.main.async { self.startRecording() }
                }
            }
            return
        }

        guard let model = modelManager.activeModel else {
            flog("startRecording: no active model")
            sessionManager.state = .error("error.modelNotLoaded".localized)
            return
        }

        flog("startRecording: starting capture, model=\(model.name)")
        sessionManager.state = .recording
        sessionManager.recordingStartTime = Date()
        audioCaptureService.startCapture()
    }

    private func stopRecordingAndTranscribe() {
        flog("stopRecordingAndTranscribe: current state=\(sessionManager.state)")
        guard sessionManager.state == .recording else {
            flog("stopRecordingAndTranscribe: rejected, not recording")
            return
        }

        let audioData = audioCaptureService.stopCapture()
        flog("stopRecordingAndTranscribe: captured \(audioData.count) bytes")
        sessionManager.state = .transcribing

        Task {
            do {
                flog("transcribe: starting")
                let result = try await transcriptionEngine.transcribe(audioData: audioData)
                flog("transcribe: result text='\(result.text.prefix(100))', lang=\(result.language)")
                await MainActor.run {
                    guard !result.text.isEmpty else {
                        flog("transcribe: empty result, showing error feedback")
                        sessionManager.state = .error("error.recognitionFailed".localized)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            if case .error = self.sessionManager.state {
                                self.sessionManager.state = .idle
                            }
                        }
                        return
                    }
                    sessionManager.state = .inserting(result.text)

                    let autoInsert = UserDefaults.standard.bool(forKey: "autoInsertText")
                    let copyClipboard = UserDefaults.standard.bool(forKey: "copyToClipboard")
                    flog("insertion: autoInsert=\(autoInsert), copyToClipboard=\(copyClipboard)")

                    if autoInsert {
                        flog("insertion: calling accessibilityService.insertText")
                        accessibilityService.insertText(result.text)
                    }

                    if copyClipboard {
                        flog("insertion: copying to clipboard")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    }

                    let duration = sessionManager.recordingStartTime.map {
                        Date().timeIntervalSince($0)
                    } ?? 0

                    historyStore.addRecord(
                        text: result.text,
                        duration: duration,
                        modelUsed: modelManager.activeModel?.name ?? "unknown",
                        language: result.language
                    )
                    flog("insertion: saved to history, duration=\(String(format: "%.1f", duration))s")

                    sessionManager.state = .done(result.text)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if case .done = self.sessionManager.state {
                            self.sessionManager.state = .idle
                        }
                    }
                }
            } catch {
                flog("transcribe: ERROR \(error)")
                await MainActor.run {
                    sessionManager.state = .error(error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if case .error = self.sessionManager.state {
                            self.sessionManager.state = .idle
                        }
                    }
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        flog("application(open:) \(urls.count) file(s), launched=\(didFinishLaunching)")
        guard didFinishLaunching else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        openFiles(urls)
    }

    @MainActor
    private func openFiles(_ urls: [URL]) {
        showSettingsWindow(tab: .transcription)
        // Straight onto the queue rather than through a notification the pane
        // has to already be listening for — that ordering only ever worked
        // because NSHostingView happens to build synchronously.
        fileQueue.enqueue(urls: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        flog("applicationWillTerminate")
        hotkeyService?.stop()
        _ = audioCaptureService?.stopCapture()
        transcriptionEngine?.unloadModel()
        floatingIndicator?.updateState(.idle)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView(
            modelManager: modelManager,
            audioCaptureService: audioCaptureService,
            accessibilityService: accessibilityService,
            onComplete: { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        .environmentObject(modelManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "window.onboarding".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: onboardingView)

        self.onboardingWindow = window

        // Activate app so the window can receive focus (LSUIElement apps need this)
        activateAndShow(window)
    }

    func showSettingsWindow(tab: SettingsTab = .general) {
        if let w = settingsWindow {
            settingsTabSelection.tab = tab
            activateAndShow(w)
            return
        }

        settingsTabSelection.tab = tab
        let view = SettingsView(selection: settingsTabSelection)
            .environmentObject(sessionManager)
            .environmentObject(modelManager)
            .environmentObject(historyStore)
            .environmentObject(transcriptionEngine as TranscriptionEngine)
            .environmentObject(fileQueue as FileTranscriptionQueue)

        let window = NSWindow(
            // Match SettingsView's fixed SwiftUI frame exactly so NSHostingView
            // never resizes (and thus re-centers) the window when switching tabs.
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.windowWidth, height: SettingsView.windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "window.settings".localized
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: view)
        // Pin the window size to our fixed content; don't let the hosting view
        // grow the window to a pane's intrinsic content size.
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        window.contentView = hostingView
        window.center()

        self.settingsWindow = window
        activateAndShow(window)
    }

    @objc func showHistoryWindow() {
        if let w = historyWindow {
            activateAndShow(w)
            return
        }

        let view = HistoryWindowView()
            .environmentObject(historyStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "window.history".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)

        self.historyWindow = window
        activateAndShow(window)
    }

    private func activateAndShow(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
