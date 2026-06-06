import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, models, indicator, history, language, pro, permissions, test

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "settings.tab.general".localized
        case .models: return "settings.tab.models".localized
        case .indicator: return "settings.tab.indicator".localized
        case .history: return "settings.tab.history".localized
        case .language: return "settings.tab.language".localized
        case .pro: return "settings.pro.title".localized
        case .permissions: return "settings.tab.permissions".localized
        case .test: return "settings.tab.test".localized
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .models: return "cpu"
        case .indicator: return "bubble.left"
        case .history: return "clock"
        case .language: return "globe"
        case .pro: return "star.fill"
        case .permissions: return "lock.shield"
        case .test: return "mic.badge.plus"
        }
    }
}

class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var selection: SettingsTabSelection
    @ObservedObject private var localization = LocalizationManager.shared

    // Window/layout geometry. The NSWindow content size in AppDelegate must match
    // `windowWidth`/`windowHeight` so NSHostingView never resizes (and re-centers)
    // the window when switching tabs.
    static let windowWidth: CGFloat = 600
    static let windowHeight: CGFloat = 400
    static let sidebarWidth: CGFloat = 180

    /// Hide the Pro tab unless the Pro experience is enabled. Flip
    /// `AppFeatures.proEnabled` to restore it.
    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .pro || AppFeatures.proEnabled }
    }

    var body: some View {
        // Fixed sidebar layout: no NavigationSplitView, so AppKit does not inject
        // a collapsible-sidebar toggle into the window toolbar. The sidebar stays
        // pinned at a fixed width for this settings window.
        //
        // The detail pane is hard-pinned to the remaining width and clipped so that
        // a wide intrinsic control (e.g. the language Picker with its long label and
        // "Системный язык" value) can never push the HStack wider and shove the
        // sidebar sideways. Without this, switching to the Language tab visibly
        // jumped the sidebar to the left.
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)

            Divider()

            detailContent
                .frame(width: Self.windowWidth - Self.sidebarWidth - 1, height: Self.windowHeight)
                .clipped()
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        // Rebuild the whole subtree on language change so every `.localized`
        // call (including the enum-backed sidebar labels) re-evaluates against
        // the freshly-set bundle.
        .id(localization.currentLanguage)
    }

    @ViewBuilder
    private var sidebar: some View {
        if #available(macOS 13.0, *) {
            List(visibleTabs, id: \.self, selection: $selection.tab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
        } else {
            VStack {
                ForEach(visibleTabs) { tab in
                    Button(action: { selection.tab = tab }) {
                        Label(tab.label, systemImage: tab.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .background(selection.tab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private var detailContent: some View {
        Group {
            switch selection.tab {
            case .general: GeneralSettingsView()
            case .models: ModelSettingsView()
            case .indicator: IndicatorSettingsView()
            case .history: HistorySettingsView()
            case .language: LanguageSettingsView()
            case .pro:
                // Defensive: if a `.pro` selection was persisted while the Pro
                // experience is hidden, don't surface the Pro panel.
                if AppFeatures.proEnabled {
                    ProSettingsView()
                } else {
                    EmptyView()
                }
            case .permissions: PermissionsSettingsView()
            case .test: TestTranscriptionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoInsertText") private var autoInsertText = true
    @AppStorage("copyToClipboard") private var copyToClipboard = false
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 63
    @State private var isRecordingHotkey = false

    var body: some View {
        Form {
            Toggle("settings.general.launchAtLogin".localized, isOn: $launchAtLogin)

            HStack {
                Text("settings.general.recordingKey".localized)
                Spacer()
                Button(action: {
                    isRecordingHotkey = true
                }) {
                    Text(isRecordingHotkey ? "settings.general.pressKey".localized : hotkeyDisplayName)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isRecordingHotkey ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                .modifier(BorderedButtonCompat())
                .modifier(OnKeyPressCompat(isRecording: $isRecordingHotkey))
                .focusable(isRecordingHotkey)
                .overlay(
                    Group {
                        if isRecordingHotkey {
                            HotkeyRecorderView { keyCode in
                                hotkeyKeyCode = keyCode
                                isRecordingHotkey = false
                            }
                            .frame(width: 0, height: 0)
                        }
                    }
                )
            }

            Toggle("settings.general.autoInsert".localized, isOn: $autoInsertText)
            Toggle("settings.general.copyToClipboard".localized, isOn: $copyToClipboard)

            Divider()

            HStack {
                Button("Экспорт логов") {
                    exportLogs()
                }
                .modifier(BorderedButtonCompat())

                Button("Очистить логи") {
                    FileLogger.shared.clear()
                }
                .modifier(BorderedButtonCompat())
                .foregroundColor(.secondary)
            }
            Text("Логи помогают диагностировать проблемы с записью и транскрибацией")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private func exportLogs() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "corvin-logs.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            let logs = FileLogger.shared.readAll()
            do {
                try logs.write(to: url, atomically: true, encoding: .utf8)
                flog("exportLogs: wrote \(logs.count) bytes to \(url.path)")
            } catch {
                flog("exportLogs: write FAILED: \(error)")
            }
        }
    }

    private var hotkeyDisplayName: String {
        keyCodeToString(hotkeyKeyCode)
    }

    private func keyCodeToString(_ keyCode: Int) -> String {
        let knownKeys: [Int: String] = [
            63: "fn",
            49: "Space",
            36: "Return",
            48: "Tab",
            51: "Delete",
            53: "Escape",
            55: "⌘",
            56: "⇧",
            58: "⌥",
            59: "⌃",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        return knownKeys[keyCode] ?? "Key \(keyCode)"
    }
}

struct OnKeyPressCompat: ViewModifier {
    @Binding var isRecording: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(KeyEquivalent("\u{1b}")) {
                if isRecording {
                    isRecording = false
                    return .handled
                }
                return .ignored
            }
        } else {
            content
        }
    }
}

struct HotkeyRecorderView: NSViewRepresentable {
    var onKeyRecorded: (Int) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onKeyRecorded = onKeyRecorded
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onKeyRecorded = onKeyRecorded
    }
}

class HotkeyRecorderNSView: NSView {
    var onKeyRecorded: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyRecorded?(Int(event.keyCode))
    }

    override func flagsChanged(with event: NSEvent) {
        // Capture modifier-only keys (fn, Shift, Cmd, etc.)
        let keyCode = Int(event.keyCode)
        if keyCode != 0 {
            onKeyRecorded?(keyCode)
        }
    }
}

// MARK: - Models

struct ModelSettingsView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        ModelManagerView()
            .environmentObject(modelManager)
    }
}

// MARK: - Indicator

struct IndicatorSettingsView: View {
    @AppStorage("indicatorEnabled") private var indicatorEnabled = true
    @AppStorage("indicatorPosition") private var indicatorPosition = "bottomCenter"
    @AppStorage("indicatorSize") private var indicatorSize = "normal"

    var body: some View {
        Form {
            Toggle("settings.indicator.show".localized, isOn: $indicatorEnabled)

            Picker("settings.indicator.position".localized, selection: $indicatorPosition) {
                Text("settings.indicator.position.bottomRight".localized).tag("bottomRight")
                Text("settings.indicator.position.bottomLeft".localized).tag("bottomLeft")
                Text("settings.indicator.position.topRight".localized).tag("topRight")
                Text("settings.indicator.position.topLeft".localized).tag("topLeft")
                Text("settings.indicator.position.bottomCenter".localized).tag("bottomCenter")
            }

            Picker("settings.indicator.size".localized, selection: $indicatorSize) {
                Text("settings.indicator.size.compact".localized).tag("compact")
                Text("settings.indicator.size.normal".localized).tag("normal")
            }
        }
        .padding()
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @AppStorage("autoCleanupPeriod") private var autoCleanupPeriod = "month"
    @EnvironmentObject var historyStore: HistoryStore

    var body: some View {
        Form {
            Picker("settings.history.autoCleanup".localized, selection: $autoCleanupPeriod) {
                Text("settings.history.period.week".localized).tag("week")
                Text("settings.history.period.month".localized).tag("month")
                Text("settings.history.period.halfYear".localized).tag("halfYear")
                Text("settings.history.period.never".localized).tag("never")
            }

            Section {
                Button("settings.history.clearAll".localized) {
                    historyStore.deleteAll()
                }
                .foregroundColor(.red)
            }
        }
        .padding()
    }
}

// MARK: - Language

struct LanguageSettingsView: View {
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Picker("settings.language.appLanguage".localized, selection: $localization.currentLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }

            Text("settings.language.restartRequired".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Pro

struct ProSettingsView: View {
    @ObservedObject var proManager = ProManager.shared
    @State private var showPaywall = false

    /// macOS is a menubar agent (LSUIElement) with no Dock icon, so use the
    /// macOS-specific copy that doesn't promise an app-icon change.
    private var descriptionKey: String {
        #if os(macOS)
        "pro.description.macos"
        #else
        "pro.description"
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if proManager.isPro {
                Image(systemName: "star.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text("pro.activated".localized)
                    .font(.headline)
                Text("pro.thankYou".localized)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "star")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text("settings.pro.title".localized)
                    .font(.headline)
                Text(descriptionKey.localized)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("settings.pro.learnMore".localized) {
                    showPaywall = true
                }
                .modifier(ProminentButtonCompat())

                Button("pro.restore".localized) {
                    proManager.triggerRestore()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showPaywall) {
            ProPaywallView()
        }
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    private let accessibilityService = AccessibilityService()
    @State private var hasAccessibility = false
    @State private var hasMicrophone = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            HStack(spacing: 8) {
                Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(hasAccessibility ? .green : .red)
                Text("settings.permissions.accessibility".localized)
                if !hasAccessibility {
                    Button("common.request".localized) {
                        requestAccessibility()
                    }
                    .modifier(BorderedButtonCompat())
                }
            }

            HStack(spacing: 8) {
                Image(systemName: hasMicrophone ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(hasMicrophone ? .green : .red)
                Text("settings.permissions.microphone".localized)
                if !hasMicrophone {
                    Button("common.request".localized) {
                        requestMicrophoneAccess()
                    }
                    .modifier(BorderedButtonCompat())
                }
            }

            Spacer()

            Button("settings.permissions.resetAll".localized) {
                resetAllPermissions()
            }
            .modifier(BorderedButtonCompat())
            .foregroundColor(.red)

            Text("settings.permissions.resetHint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            checkPermissions()
            startPolling()
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func checkPermissions() {
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            DispatchQueue.main.async {
                let newAx = AXIsProcessTrusted()
                let newMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if newAx != hasAccessibility { hasAccessibility = newAx }
                if newMic != hasMicrophone { hasMicrophone = newMic }
                if newAx && newMic {
                    pollTimer?.invalidate()
                    pollTimer = nil
                }
            }
        }
    }

    private func requestAccessibility() {
        // Reset stale TCC entry so the system prompt works again
        let bundleId = Bundle.main.bundleIdentifier ?? "com.corvinvoice.mac"
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleId]
        try? reset.run()
        reset.waitUntilExit()

        // Show system prompt to add app to Accessibility list
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func resetAllPermissions() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.corvinvoice.mac"

        // Reset Accessibility
        let axReset = Process()
        axReset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        axReset.arguments = ["reset", "Accessibility", bundleId]
        try? axReset.run()
        axReset.waitUntilExit()

        // Reset Microphone
        let micReset = Process()
        micReset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        micReset.arguments = ["reset", "Microphone", bundleId]
        try? micReset.run()
        micReset.waitUntilExit()

        hasAccessibility = false
        hasMicrophone = false

        // Re-request both
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            requestMicrophoneAccess()
        }
        startPolling()
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                hasMicrophone = granted
            }
        }
    }
}

import AVFoundation
