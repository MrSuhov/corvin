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
    private var diarizationModels: DiarizationModelStore!
    private var transcriptRegistry: TranscriptRegistry!
    private var vocabularyStore: VocabularyStore!
    private var dictationCoordinator: DictationCoordinator!
    private(set) var callIndex: CallIndex!
    private(set) var callRecorder: CallRecorder!
    private(set) var cleanupService: CleanupService!

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
        ].merging(DictationSettings.defaults) { current, _ in current }
            .merging(CallSettings.defaults) { current, _ in current }
            .merging(CleanupSettings.defaults) { current, _ in current })

        accessibilityService = AccessibilityService()
        layoutSwitchService = LayoutSwitchService(accessibility: accessibilityService)
        audioCaptureService = AudioCaptureService()
        transcriptionEngine = TranscriptionEngine(modelManager: modelManager)
        // App-lifetime owner: the settings pane that drives this queue is torn
        // down whenever the user switches tabs or the interface language, so a
        // view-owned queue would die mid-batch.
        diarizationModels = DiarizationModelStore()
        transcriptRegistry = TranscriptRegistry()
        vocabularyStore = VocabularyStore()
        fileQueue = FileTranscriptionQueue(engine: transcriptionEngine,
                                          sessionManager: sessionManager,
                                          modelManager: modelManager,
                                          diarizationModels: diarizationModels,
                                          registry: transcriptRegistry,
                                          vocabularies: vocabularyStore)
        callIndex = CallIndex()
        // Calls whose audio the user deleted by hand are not worth remembering,
        // unless a transcript still points at them.
        callIndex.prune(keeping: Set(transcriptRegistry.records.map { $0.sourcePath }))
        // So a call transcript can name the app it came from. Weak: the index
        // outlives no one here, but the queue must not be what keeps it alive.
        fileQueue.callInfo = { [weak callIndex] url in callIndex?.info(for: url) }
        callRecorder = CallRecorder(fileQueue: fileQueue, callIndex: callIndex)
        cleanupService = CleanupService(registry: transcriptRegistry, callIndex: callIndex,
                                        historyStore: historyStore, fileQueue: fileQueue)
        cleanupService.start()
        hotkeyService = HotkeyService()
        dictationCoordinator = DictationCoordinator(
            sessionManager: sessionManager,
            modelManager: modelManager,
            historyStore: historyStore,
            audioCapture: audioCaptureService,
            accessibility: accessibilityService,
            engine: transcriptionEngine
        )

        statusBarController = StatusBarController(
            sessionManager: sessionManager,
            modelManager: modelManager,
            historyStore: historyStore,
            callRecorder: callRecorder,
            appDelegate: self
        )

        floatingIndicator = FloatingIndicatorController(sessionManager: sessionManager, callRecorder: callRecorder)

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
            self?.dictationCoordinator.keyDown()
        }

        hotkeyService.onKeyUp = { [weak self] in
            self?.dictationCoordinator.keyUp()
        }

        hotkeyService.onLayoutSwitchTap = { [weak self] in
            self?.layoutSwitchService.convertTextAtCursor()
        }

        sessionManager.$state
            .sink { [weak self] state in
                // Both controllers read the main-actor `CallRecorder`.
                Task { @MainActor in
                    self?.statusBarController.updateState(state)
                    self?.floatingIndicator.updateState(state)
                }
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        flog("application(open:) \(urls.count) file(s), launched=\(didFinishLaunching)")
        guard didFinishLaunching else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        openFiles(urls)
    }

    /// Files opened from Finder, the Dock or the menubar: queued, and shown
    /// selected in the Files tab.
    @MainActor
    func openFiles(_ urls: [URL]) {
        // Straight onto the queue rather than through a notification the pane
        // has to already be listening for — that ordering only ever worked
        // because NSHostingView happens to build synchronously.
        let accepted = fileQueue.enqueue(urls: urls)
        showSettingsWindow(tab: .files)
        settingsTabSelection.show(added: accepted)
    }

    func applicationWillTerminate(_ notification: Notification) {
        flog("applicationWillTerminate")
        hotkeyService?.stop()
        callRecorder?.finishForTermination()
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

    func showSettingsWindow(tab: SettingsTab = .settings) {
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
            .environmentObject(diarizationModels as DiarizationModelStore)
            .environmentObject(transcriptRegistry as TranscriptRegistry)
            .environmentObject(callIndex as CallIndex)
            .environmentObject(cleanupService as CleanupService)
            .environmentObject(vocabularyStore as VocabularyStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.windowWidth, height: SettingsView.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: SettingsView.minWindowWidth,
                                       height: SettingsView.minWindowHeight)
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
        // Remembers where the user put it and how big they made it; centre only
        // the very first time.
        window.setFrameAutosaveName("CorvinSettingsWindow")
        if window.frame.origin == .zero { window.center() }

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
