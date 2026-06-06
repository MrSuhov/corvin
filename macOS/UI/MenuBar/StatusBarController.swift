import AppKit
import SwiftUI
import Combine

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let sessionManager: SessionManager
    private let modelManager: ModelManager
    private let historyStore: HistoryStore
    private weak var appDelegate: AppDelegate?

    init(sessionManager: SessionManager, modelManager: ModelManager, historyStore: HistoryStore, appDelegate: AppDelegate) {
        self.sessionManager = sessionManager
        self.modelManager = modelManager
        self.historyStore = historyStore
        self.appDelegate = appDelegate

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = Self.loadStatusBarIcon()
        }

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

    func updateState(_ state: SessionState) {
        guard let button = statusItem.button else { return }

        switch state {
        case .idle:
            button.image = Self.loadStatusBarIcon()
            button.contentTintColor = nil
        case .recording:
            button.image = Self.loadStatusBarIcon()
            button.contentTintColor = .systemRed
        case .transcribing:
            button.image = Self.loadStatusBarIcon()
            button.contentTintColor = .systemOrange
        case .inserting, .done:
            button.image = Self.loadStatusBarIcon()
            button.contentTintColor = .systemGreen
        case .error:
            button.image = Self.loadStatusBarIcon()
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

        let updates = NSMenuItem(title: "Проверить обновления...", action: #selector(UpdaterService.checkForUpdates(_:)), keyEquivalent: "")
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

    @objc private func showAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
