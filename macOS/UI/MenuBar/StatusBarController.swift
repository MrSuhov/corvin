import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let sessionManager: SessionManager
    private let modelManager: ModelManager
    private let historyStore: HistoryStore
    private let callRecorder: CallRecorder
    private weak var appDelegate: AppDelegate?

    /// Filled when it opens; see `fillCallApps`.
    private weak var callAppsMenu: NSMenu?
    private var offeredApps: [CallApp] = []
    /// Its title carries the elapsed time, refreshed each time the menu opens.
    private weak var callStopItem: NSMenuItem?

    /// Mirrors `UpdaterService.pendingUpdateVersion`; drives both the badge on
    /// the icon and the "Обновить" menu item.
    private var pendingUpdateVersion: String?
    private var updateProgress: UpdaterService.Progress?
    private var lastState: SessionState = .idle
    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: SessionManager, modelManager: ModelManager, historyStore: HistoryStore,
         callRecorder: CallRecorder, appDelegate: AppDelegate) {
        self.sessionManager = sessionManager
        self.modelManager = modelManager
        self.historyStore = historyStore
        self.callRecorder = callRecorder
        self.appDelegate = appDelegate

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = Self.statusBarIcon(badged: false)
        }

        UpdaterService.shared.$pendingUpdateVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                guard let self = self, self.pendingUpdateVersion != version else { return }
                self.pendingUpdateVersion = version
                self.updateState(self.lastState)
            }
            .store(in: &cancellables)

        // The update runs headlessly, so this menu item is the only place the
        // user can see it happening at all.
        UpdaterService.shared.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self = self, self.updateProgress != progress else { return }
                self.updateProgress = progress
                self.updateState(self.lastState)
            }
            .store(in: &cancellables)

        // A call records alongside dictation: it has its own menu items, and
        // the icon stays red for it while dictation is idle. Received on the
        // main queue so the sink runs after `@Published` has stored the value.
        callRecorder.$state.combineLatest(callRecorder.$warning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateState(self.lastState)
            }
            .store(in: &cancellables)

        buildMenu()

        // AppKit menus are outside SwiftUI reactivity; rebuild on language change.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged),
            name: .appLanguageChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func languageChanged() {
        buildMenu()
    }

    private static func loadStatusBarIcon() -> NSImage? {
        // Try loading from bundle resources (SPM)
        if let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        // Fallback to named image (Xcode)
        if let image = NSImage(named: "StatusBarIcon") {
            image.isTemplate = true
            return image
        }
        // Final fallback to SF Symbol
        return NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Corvin")
    }

    /// The status bar icon, optionally carrying an update badge in its top-right
    /// corner.
    ///
    /// The badge is baked into the same template image as the glyph, so it takes
    /// the menubar's foreground colour — white on a dark menubar, black on a
    /// light one. A transparent ring is punched around it first so it stays
    /// legible where it overlaps the glyph.
    private static func statusBarIcon(badged: Bool) -> NSImage? {
        guard let base = loadStatusBarIcon() else { return nil }
        guard badged else { return base }

        let size = base.size
        guard size.width > 0, size.height > 0 else { return base }

        // Drawn through a handler rather than lockFocus so AppKit can re-render
        // it at whatever backing scale the current screen needs.
        let badgedIcon = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)

            let diameter = max(4, rect.width * 0.34)
            let dot = NSRect(
                x: rect.maxX - diameter,
                y: rect.maxY - diameter,
                width: diameter,
                height: diameter
            )

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // Colour is irrelevant in a template image — only alpha survives.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()

            return true
        }
        badgedIcon.isTemplate = true
        return badgedIcon
    }

    func updateState(_ state: SessionState) {
        lastState = state

        guard let button = statusItem.button else { return }

        button.image = Self.statusBarIcon(badged: pendingUpdateVersion != nil)

        switch state {
        case .idle:
            button.contentTintColor = callRecorder.isRecording ? .systemRed : nil
        case .recording:
            button.contentTintColor = .systemRed
        case .transcribing:
            button.contentTintColor = .systemOrange
        case .inserting, .done:
            button.contentTintColor = .systemGreen
        case .error:
            button.contentTintColor = .systemYellow
        }

        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Status
        let statusText: String
        switch sessionManager.state {
        case .idle:
            if case .recording(let app, _) = callRecorder.state {
                statusText = "call.menu.status.recording".localized(with: app.name)
            } else {
                statusText = "menu.status.ready".localized
            }
        case .recording: statusText = "menu.status.recording".localized
        case .transcribing: statusText = "menu.status.transcribing".localized
        case .inserting: statusText = "menu.status.inserting".localized
        case .done: statusText = "menu.status.done".localized
        case .error(let msg): statusText = "menu.status.error".localized(with: msg)
        }
        let statusItem = NSMenuItem(title: "● Corvin — \(statusText)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        // File transcription
        let transcribeFile = NSMenuItem(
            title: "menu.transcribeFile".localized,
            action: #selector(showSettingsTranscription),
            keyEquivalent: ""
        )
        transcribeFile.target = self
        menu.addItem(transcribeFile)
        menu.addItem(makeCallItem())
        if let warning = callRecorder.warning {
            let item = NSMenuItem(title: warning.text, action: #selector(openSystemAudioSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())

        // Recent records
        let recentTitle = NSMenuItem(title: "menu.recent".localized, action: nil, keyEquivalent: "")
        recentTitle.isEnabled = false
        menu.addItem(recentTitle)

        let recent = Array(historyStore.records.prefix(3))
        if recent.isEmpty {
            let empty = NSMenuItem(title: "  " + "menu.recent.empty".localized, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for record in recent {
                let preview = String(record.text.prefix(35))
                let item = NSMenuItem(title: "  \"\(preview)...\"", action: #selector(copyRecord(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = record.text
                menu.addItem(item)
            }
        }

        let historyItem = NSMenuItem(title: "menu.showHistory".localized, action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(NSMenuItem.separator())

        // Model info
        if let model = modelManager.activeModel {
            let modelItem = NSMenuItem(title: "menu.model".localized(with: model.name, model.size), action: nil, keyEquivalent: "")
            modelItem.isEnabled = false
            menu.addItem(modelItem)
        }
        let changeModel = NSMenuItem(title: "menu.changeModel".localized, action: #selector(showSettingsModels), keyEquivalent: "")
        changeModel.target = self
        menu.addItem(changeModel)
        menu.addItem(NSMenuItem.separator())

        // Settings & Quit
        let settings = NSMenuItem(title: "menu.settings".localized, action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // One slot, three states. Idle it starts a silent probe — no window, no
        // app activation, the answer arrives as the dot on the icon. With a
        // version found it becomes the install action. While the update runs it
        // reports progress and is not clickable, since the update has no UI of
        // its own to show it in.
        let updates: NSMenuItem
        if let progress = updateProgress {
            updates = NSMenuItem(title: Self.progressTitle(progress), action: nil, keyEquivalent: "")
            updates.isEnabled = false
        } else if let version = pendingUpdateVersion {
            updates = NSMenuItem(
                title: "menu.updateTo".localized(with: version),
                action: #selector(UpdaterService.installUpdate(_:)),
                keyEquivalent: ""
            )
            updates.target = UpdaterService.shared
        } else {
            updates = NSMenuItem(
                title: "menu.checkUpdates".localized,
                action: #selector(UpdaterService.checkForUpdatesInBackground(_:)),
                keyEquivalent: ""
            )
            updates.target = UpdaterService.shared
        }
        menu.addItem(updates)

        let about = NSMenuItem(title: "menu.about".localized, action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "menu.quit".localized, action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        self.statusItem.menu = menu
    }

    // MARK: - Call recording

    private func makeCallItem() -> NSMenuItem {
        callStopItem = nil
        switch callRecorder.state {
        case .recording(let app, let since):
            let item = NSMenuItem(title: Self.stopTitle(app, since: since),
                                  action: #selector(stopCallRecording), keyEquivalent: "")
            item.target = self
            callStopItem = item
            return item
        case .starting:
            return disabledItem("call.menu.starting".localized)
        case .finishing:
            return disabledItem("call.menu.finishing".localized)
        case .idle, .failed:
            guard CallRecorder.isSupported else {
                return disabledItem("call.menu.requiresMacOS13".localized)
            }
            let item = NSMenuItem(title: "call.menu.record".localized, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.delegate = self
            callAppsMenu = submenu
            item.submenu = submenu
            return item
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func stopTitle(_ app: CallApp, since: Date) -> String {
        "call.menu.stop".localized(with: app.name, CallIndicatorView.elapsed(since: since))
    }

    /// Listed when the submenu opens rather than when the menu is built: which
    /// apps run and play audio changes all the time.
    fileprivate func fillCallApps(_ menu: NSMenu) {
        menu.removeAllItems()
        offeredApps = AudioAppCatalog.apps(lastUsed: callRecorder.lastBundleID)
        guard !offeredApps.isEmpty else {
            menu.addItem(disabledItem("call.menu.noApps".localized))
            return
        }
        for (index, app) in offeredApps.enumerated() {
            let title = app.isPlayingAudio ? "call.menu.appPlaying".localized(with: app.name) : app.name
            let item = NSMenuItem(title: title, action: #selector(startCallRecording(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = AudioAppCatalog.icon(for: app)
            menu.addItem(item)
        }
    }

    fileprivate func refreshCallStopItem() {
        guard let item = callStopItem, case .recording(let app, let since) = callRecorder.state else { return }
        item.title = Self.stopTitle(app, since: since)
    }

    @objc private func startCallRecording(_ sender: NSMenuItem) {
        guard offeredApps.indices.contains(sender.tag) else { return }
        callRecorder.start(app: offeredApps[sender.tag])
    }

    @objc private func stopCallRecording() {
        callRecorder.stop()
    }

    @objc private func openSystemAudioSettings() {
        CallRecorder.openSystemAudioSettings()
    }

    private static func progressTitle(_ progress: UpdaterService.Progress) -> String {
        func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }

        switch progress {
        case .starting:
            return "menu.update.updating".localized
        case .downloading(let fraction):
            guard let fraction = fraction else { return "menu.update.downloading".localized }
            return "menu.update.downloadingPercent".localized(with: percent(fraction))
        case .extracting(let fraction):
            return "menu.update.extracting".localized(with: percent(fraction))
        case .installing:
            return "menu.update.installing".localized
        }
    }

    @objc private func copyRecord(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func showHistory() {
        appDelegate?.showHistoryWindow()
    }

    @objc private func showSettings() {
        appDelegate?.showSettingsWindow()
    }

    @objc private func showSettingsModels() {
        appDelegate?.showSettingsWindow(tab: .models)
    }

    @objc private func showSettingsTranscription() {
        appDelegate?.showSettingsWindow(tab: .transcription)
    }

    @objc private func showAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === callAppsMenu {
            fillCallApps(menu)
        } else {
            refreshCallStopItem()
        }
    }
}
