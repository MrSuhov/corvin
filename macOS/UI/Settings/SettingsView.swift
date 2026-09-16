import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

/// The sidebar. Everything that used to be a tab of its own — general,
/// language, indicator, layout, cleanup, permissions — is a section of
/// `.settings` now; only the three places with real work in them stay.
enum SettingsTab: String, CaseIterable, Identifiable {
    case transcription, models, history, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transcription: return "settings.tab.transcription".localized
        case .models: return "settings.tab.models".localized
        case .history: return "settings.tab.history".localized
        case .settings: return "settings.tab.settings".localized
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "mic.badge.plus"
        case .models: return "cpu"
        case .history: return "clock"
        case .settings: return "gear"
        }
    }
}

class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .settings
}

struct SettingsView: View {
    @ObservedObject var selection: SettingsTabSelection
    @ObservedObject private var localization = LocalizationManager.shared

    // Window/layout geometry. `windowWidth`/`windowHeight` are the size the
    // window opens at the first time; it is resizable, and AppDelegate pins its
    // minimum to `minWindowWidth`/`minWindowHeight`.
    static let windowWidth: CGFloat = 900
    static let windowHeight: CGFloat = 600
    static let sidebarWidth: CGFloat = 200
    /// Below this the History card and the settings sections stop being
    /// readable; AppDelegate pins the window to it.
    static let minWindowWidth: CGFloat = 720
    static let minWindowHeight: CGFloat = 460

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

            // Still clipped: a control with a wide intrinsic size (the language
            // picker, once) must not be able to push the HStack wider and shove
            // the sidebar sideways.
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(minWidth: Self.minWindowWidth, maxWidth: .infinity,
               minHeight: Self.minWindowHeight, maxHeight: .infinity)
        // Rebuild the whole subtree on language change so every `.localized`
        // call (including the enum-backed sidebar labels) re-evaluates against
        // the freshly-set bundle.
        .id(localization.currentLanguage)
    }

    @ViewBuilder
    private var sidebar: some View {
        if #available(macOS 13.0, *) {
            List(SettingsTab.allCases, id: \.self, selection: $selection.tab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
        } else {
            VStack {
                ForEach(SettingsTab.allCases) { tab in
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
            case .transcription: TestTranscriptionView()
            case .models: ModelSettingsView()
            case .history: HistoryFilesView()
            case .settings: ConsolidatedSettingsView()
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
    @AppStorage(DictationSettings.realtimeKey) private var realtimeDictation = false
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 63
    @State private var isRecordingHotkey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Toggle("settings.general.realtime".localized, isOn: $realtimeDictation)
                .disabled(!autoInsertText)
            Text("settings.general.realtime.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("settings.general.copyToClipboard".localized, isOn: $copyToClipboard)

            Divider()

            HStack {
                Button("logs.export".localized) {
                    exportLogs()
                }
                .modifier(BorderedButtonCompat())

                Button("logs.clear".localized) {
                    FileLogger.shared.clear()
                }
                .modifier(BorderedButtonCompat())
                .foregroundColor(.secondary)
            }
            Text("logs.hint".localized)
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
        ModifierKey.displayName(forKeyCode: hotkeyKeyCode)
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

// MARK: - Layout switching

struct LayoutSwitchSettingsView: View {
    @AppStorage("layoutSwitchEnabled") private var layoutSwitchEnabled = true
    @AppStorage("layoutSwitchChangesInputSource") private var changesInputSource = true
    @AppStorage("layoutSwitchKeyCode") private var layoutSwitchKeyCode = ModifierKey.option.canonicalKeyCode
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = ModifierKey.function.canonicalKeyCode
    @State private var isRecordingHotkey = false
    @State private var rejectedNonModifier = false

    private var keyName: String {
        ModifierKey.displayName(forKeyCode: layoutSwitchKeyCode)
    }

    /// The same physical key cannot mean both "record" and "switch layout".
    private var conflictsWithRecording: Bool {
        guard let switchKey = ModifierKey.from(keyCode: layoutSwitchKeyCode) else { return false }
        return switchKey == ModifierKey.from(keyCode: hotkeyKeyCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("settings.layout.enabled".localized(with: keyName), isOn: $layoutSwitchEnabled)

            Text("settings.layout.hint".localized(with: keyName))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("settings.layout.key".localized)
                Spacer()
                Button(action: { isRecordingHotkey = true }) {
                    Text(isRecordingHotkey
                         ? "settings.general.pressKey".localized
                         : ModifierKey.displayName(forKeyCode: layoutSwitchKeyCode))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isRecordingHotkey ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                .modifier(BorderedButtonCompat())
                .modifier(OnKeyPressCompat(isRecording: $isRecordingHotkey))
                .focusable(isRecordingHotkey)
                .disabled(!layoutSwitchEnabled)
                .overlay(
                    Group {
                        if isRecordingHotkey {
                            HotkeyRecorderView { keyCode in
                                // Only modifiers can be tapped: a letter would
                                // type itself before we ever saw the release.
                                if let modifier = ModifierKey.from(keyCode: keyCode) {
                                    layoutSwitchKeyCode = modifier.canonicalKeyCode
                                    rejectedNonModifier = false
                                    isRecordingHotkey = false
                                } else {
                                    rejectedNonModifier = true
                                }
                            }
                            .frame(width: 0, height: 0)
                        }
                    }
                )
            }

            if rejectedNonModifier {
                Text("settings.layout.key.modifiersOnly".localized)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if conflictsWithRecording {
                Label("settings.layout.optionConflict".localized, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("settings.layout.changeInputSource".localized, isOn: $changesInputSource)
                .disabled(!layoutSwitchEnabled)

            Text("settings.layout.changeInputSource.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("settings.layout.compatibility".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}

// MARK: - Indicator

struct IndicatorSettingsView: View {
    @AppStorage("indicatorEnabled") private var indicatorEnabled = true
    @AppStorage("indicatorPosition") private var indicatorPosition = "bottomCenter"
    @AppStorage("indicatorSize") private var indicatorSize = "normal"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

// MARK: - Cleanup

/// Three periods, because the three things being deleted are nothing alike: an
/// hour of call audio is ~20 MB, a transcript is a few kilobytes, and dictation
/// history is rows in a database.
struct CleanupSettingsView: View {
    @AppStorage(CleanupSettings.callAudioKey) private var callAudioPeriod = CleanupPeriod.never.rawValue
    @AppStorage(CleanupSettings.transcriptsKey) private var transcriptsPeriod = CleanupPeriod.never.rawValue
    /// Registered as `never` as well. The picker used to default to `month`
    /// while the registered default said `never` — the kind of mismatch that
    /// deletes someone's history by surprise.
    @AppStorage(CleanupSettings.dictationKey) private var dictationPeriod = CleanupPeriod.never.rawValue
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject var cleanup: CleanupService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            periodPicker("settings.cleanup.callAudio".localized, $callAudioPeriod)
            periodPicker("settings.cleanup.transcripts".localized, $transcriptsPeriod)
            periodPicker("settings.cleanup.dictation".localized, $dictationPeriod)

            Text("settings.cleanup.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("settings.cleanup.runNow".localized) { cleanup.run(force: true) }
                    .modifier(BorderedButtonCompat())
                    .disabled(cleanup.isRunning)

                Button("settings.history.clearAll".localized) { historyStore.deleteAll() }
                    .modifier(BorderedButtonCompat())
                    .foregroundColor(.red)
            }

            if let summary = cleanup.lastSummary, let lastRun = cleanup.lastRun {
                Text("settings.cleanup.summary".localized(
                    with: Self.dateFormatter.string(from: lastRun),
                    summary.files,
                    Self.byteFormatter.string(fromByteCount: summary.bytes)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private func periodPicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(CleanupPeriod.allCases) { period in
                Text(period.label).tag(period.rawValue)
            }
        }
        // Capped width: an intrinsically wide picker in this window used to
        // shove the sidebar sideways.
        .frame(maxWidth: 360, alignment: .leading)
        .onChange(of: selection.wrappedValue) { newValue in
            confirmIfDestructive(newValue, selection)
        }
    }

    /// Switching a period on starts deleting files for good, so ask once.
    private func confirmIfDestructive(_ newValue: String, _ selection: Binding<String>) {
        guard newValue != CleanupPeriod.never.rawValue else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "settings.cleanup.confirm.title".localized
        alert.informativeText = "settings.cleanup.confirm.message".localized
        alert.addButton(withTitle: "settings.cleanup.confirm.enable".localized)
        alert.addButton(withTitle: "common.cancel".localized)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() != .alertFirstButtonReturn {
            selection.wrappedValue = CleanupPeriod.never.rawValue
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

// MARK: - Language

struct LanguageSettingsView: View {
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("settings.language.appLanguage".localized, selection: $localization.currentLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }

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
    @State private var hasScreenCapture = false
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

            callRecordingPermission

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
        .onAppear { checkPermissions() }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        // Returning from System Settings is when a permission actually changes,
        // and it costs nothing to check then. The pane is now a section of an
        // always-mounted tab, so a permanent 2-second timer would run for as
        // long as the window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
    }

    /// Recording a call needs the other app's audio: "System Audio Recording"
    /// for a process tap on 14.2+, which has no API to read its status, or
    /// Screen Recording for ScreenCaptureKit on 13–14.1.
    @ViewBuilder
    private var callRecordingPermission: some View {
        if #available(macOS 14.2, *) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle")
                    .foregroundColor(.secondary)
                Text("settings.permissions.systemAudio".localized)
                Button("call.permissions.open".localized) {
                    CallRecorder.openSystemAudioSettings()
                }
                .modifier(BorderedButtonCompat())
            }
        } else if #available(macOS 13.0, *) {
            HStack(spacing: 8) {
                Image(systemName: hasScreenCapture ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(hasScreenCapture ? .green : .red)
                Text("settings.permissions.screenRecording".localized)
                if !hasScreenCapture {
                    Button("common.request".localized) {
                        if !CGRequestScreenCaptureAccess() {
                            CallRecorder.openSystemAudioSettings()
                        }
                    }
                    .modifier(BorderedButtonCompat())
                }
            }
        }
    }

    private func checkPermissions() {
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasScreenCapture = CGPreflightScreenCaptureAccess()
    }

    /// A short burst after asking for something, not a permanent timer: the
    /// system dialog is answered within seconds or not at all.
    private func startPolling(for duration: TimeInterval = 30) {
        pollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(duration)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                let newAx = AXIsProcessTrusted()
                let newMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if newAx != hasAccessibility { hasAccessibility = newAx }
                if newMic != hasMicrophone { hasMicrophone = newMic }
                if (newAx && newMic) || Date() > deadline {
                    pollTimer?.invalidate()
                    pollTimer = nil
                }
            }
        }
    }

    private func requestAccessibility() {
        // Reset stale TCC entry so the system prompt works again
        let bundleId = Bundle.main.bundleIdentifier ?? "com.corvinvoice.ios"
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
        startPolling()
    }

    private func resetAllPermissions() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.corvinvoice.ios"

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
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            // First time: the system prompt will appear.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    hasMicrophone = granted
                    if !granted { openMicrophonePrivacySettings() }
                }
            }

        case .denied, .restricted:
            // Already denied: requestAccess would silently no-op (no prompt).
            // Reset the stale TCC entry so the system prompt works again,
            // mirroring requestAccessibility().
            let bundleId = Bundle.main.bundleIdentifier ?? "com.corvinvoice.ios"
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Microphone", bundleId]
            try? reset.run()
            reset.waitUntilExit()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        hasMicrophone = granted
                        // If tccutil couldn't reset (e.g. MDM-managed), fall back
                        // to opening the privacy pane so the user can toggle it.
                        if !granted { openMicrophonePrivacySettings() }
                    }
                }
            }

        case .authorized:
            hasMicrophone = true

        @unknown default:
            break
        }
    }

    private func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AVFoundation
