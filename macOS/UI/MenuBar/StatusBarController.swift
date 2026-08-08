import AppKit
import SwiftUI
import Combine

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let sessionManager: SessionManager
    private let modelManager: ModelManager
    private let historyStore: HistoryStore
    private weak var appDelegate: AppDelegate?

    /// Mirrors `UpdaterService.pendingUpdateVersion`; drives both the badge on
    /// the icon and the "Обновить" menu item.
    private var pendingUpdateVersion: String?
    private var lastState: SessionState = .idle
    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: SessionManager, modelManager: ModelManager, historyStore: HistoryStore, appDelegate: AppDelegate) {
        self.sessionManager = sessionManager
        self.modelManager = modelManager
        self.historyStore = historyStore
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
            button.contentTintColor = nil
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
        case .idle: statusText = "готов"
        case .recording: statusText = "запись..."
        case .transcribing: statusText = "распознаю..."
        case .inserting: statusText = "вставка..."
        case .done: statusText = "готово"
        case .error(let msg): statusText = "ошибка: \(msg)"
        }
        let statusItem = NSMenuItem(title: "● Corvin — \(statusText)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        // File transcription
        let transcribeFile = NSMenuItem(
            title: "Распознать файл...",
            action: #selector(showSettingsTranscription),
            keyEquivalent: ""
        )
        transcribeFile.target = self
        menu.addItem(transcribeFile)
        menu.addItem(NSMenuItem.separator())

        // Recent records
        let recentTitle = NSMenuItem(title: "Последние записи:", action: nil, keyEquivalent: "")
        recentTitle.isEnabled = false
        menu.addItem(recentTitle)

        let recent = Array(historyStore.records.prefix(3))
        if recent.isEmpty {
            let empty = NSMenuItem(title: "  Пока нет записей", action: nil, keyEquivalent: "")
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

        let historyItem = NSMenuItem(title: "Показать всю историю...", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(NSMenuItem.separator())

        // Model info
        if let model = modelManager.activeModel {
            let modelItem = NSMenuItem(title: "Модель: \(model.name) (\(model.size))", action: nil, keyEquivalent: "")
            modelItem.isEnabled = false
            menu.addItem(modelItem)
        }
        let changeModel = NSMenuItem(title: "Сменить модель...", action: #selector(showSettingsModels), keyEquivalent: "")
        changeModel.target = self
        menu.addItem(changeModel)
        menu.addItem(NSMenuItem.separator())

        // Settings & Quit
        let settings = NSMenuItem(title: "Настройки...", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Two different actions behind one slot. With nothing found, the item
        // kicks off a silent probe — no window, no app activation, the answer
        // arrives as the dot on the icon. Once a version is known, the same slot
        // becomes the install action, which is where Sparkle's UI belongs.
        let updates: NSMenuItem
        if let version = pendingUpdateVersion {
            updates = NSMenuItem(
                title: "Обновить до \(version)",
                action: #selector(UpdaterService.installUpdate(_:)),
                keyEquivalent: ""
            )
        } else {
            updates = NSMenuItem(
                title: "Проверить обновления...",
                action: #selector(UpdaterService.checkForUpdatesInBackground(_:)),
                keyEquivalent: ""
            )
        }
        updates.target = UpdaterService.shared
        menu.addItem(updates)

        let about = NSMenuItem(title: "О программе", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.statusItem.menu = menu
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
