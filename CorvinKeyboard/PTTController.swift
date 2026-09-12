import Foundation
import UIKit
import Combine

class PTTController: ObservableObject {
    /// True only once the host app has confirmed it is capturing audio.
    @Published var isRecording = false
    /// True while waiting for that confirmation — the mic key must not claim to be
    /// recording before the host answers, otherwise a dead host looks like a working one.
    @Published var isStarting = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?
    @Published var isTranscribing = false

    private let ipcClient = IPCClient()
    private weak var textProxy: UITextDocumentProxy?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var startRecordingTask: Task<Void, Never>?
    /// Set when the user releases the key before the host confirmed the start.
    private var pendingStop = false

    init(textDocumentProxy: UITextDocumentProxy) {
        self.textProxy = textDocumentProxy
    }

    // MARK: - Waking the host app

    /// Set by `KeyboardViewController`. Opening the app needs the responder
    /// chain, and only the view controller sits on it.
    weak var inputViewController: UIInputViewController?

    var canWakeHost: Bool { inputViewController != nil }

    /// Open Corvin, telling it which app to send the user back to.
    func wakeHostApp() {
        guard let controller = inputViewController else { return }
        let host = HostAppLauncher.hostBundleID(of: controller)
        flog("PTT: waking host app, return target = \(host ?? "unknown")")
        guard let url = HostAppLauncher.wakeURL(returningTo: host),
              HostAppLauncher.open(url, from: controller) else {
            flog("PTT: no UIApplication on the responder chain, cannot open the app")
            lastError = "keyboard.error.wakeFailed".localized
            return
        }
    }

    // MARK: - Keyboard lifecycle

    /// Announce ourselves to the host app. Doubles as the liveness check —
    /// a failure here is the only reliable way to know the host was suspended.
    func keyboardDidAppear() {
        Task { @MainActor in
            let alive = await ipcClient.notifyKeyboard(active: true)
            if alive {
                if lastError == IPCError.hostAsleepMessage { lastError = nil }
            } else {
                flog("PTT: host not reachable on keyboard appear (\(hostLivenessDescription()))")
                lastError = IPCError.hostAsleepMessage
            }
        }
    }

    /// Tell the host it can drop into low-power mode.
    func keyboardWillDisappear() {
        Task { @MainActor in
            await ipcClient.notifyKeyboard(active: false)
        }
    }

    /// Reads the host's keep-alive beacon from the App Group. Diagnostics only —
    /// it tells the log whether background mode was ever armed or died after a while.
    private func hostLivenessDescription() -> String {
        guard let defaults = UserDefaults(suiteName: SharedDefaults.appGroup) else {
            return "no app group"
        }
        guard defaults.bool(forKey: SharedDefaults.backgroundModeEnabled) else {
            return "background mode disabled"
        }
        let beacon = defaults.double(forKey: SharedDefaults.hostAliveAt)
        guard beacon > 0 else { return "background mode on, never reported alive" }
        let age = Date().timeIntervalSince1970 - beacon
        return "last alive \(String(format: "%.0f", age))s ago"
    }

    // MARK: - Push to talk

    func startRecording() {
        flog("startRecording called, isRecording=\(isRecording), isStarting=\(isStarting)")
        guard !isRecording, !isStarting, !isTranscribing else {
            flog("startRecording: busy, ignoring")
            return
        }

        // Clear any previous error at the start of a new attempt, so a retry never
        // costs the user an extra tap.
        lastError = nil
        pendingStop = false
        isStarting = true

        startRecordingTask = Task { @MainActor in
            do {
                flog("startRecording: calling IPC...")
                try await ipcClient.startRecording()
            } catch {
                if Task.isCancelled { return }
                flog("startRecording: IPC FAILED: \(error.localizedDescription)")
                isStarting = false
                pendingStop = false
                lastError = error.localizedDescription
                return
            }

            if Task.isCancelled { return }
            flog("startRecording: IPC success")
            isStarting = false

            if pendingStop {
                // Released before the host answered — go straight to transcription
                // instead of silently throwing the take away.
                flog("startRecording: pending stop, transcribing immediately")
                pendingStop = false
                beginTranscription()
                return
            }

            isRecording = true
            recordingStartTime = Date()
            startDurationTimer()

            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }

    func stopRecording() {
        flog("stopRecording called, isRecording=\(isRecording), isStarting=\(isStarting)")

        if isStarting {
            // The host has not confirmed yet; transcribe as soon as it does.
            flog("stopRecording: start still in flight, deferring")
            pendingStop = true
            return
        }

        guard isRecording else {
            flog("stopRecording: not recording, ignoring")
            return
        }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        flog("stopRecording: duration=\(String(format: "%.2f", duration))s")

        beginTranscription()

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // MARK: - Internals

    private func startDurationTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func beginTranscription() {
        isRecording = false
        isStarting = false
        startRecordingTask = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
        recordingStartTime = nil
        isTranscribing = true

        Task { @MainActor in
            do {
                flog("stopRecording: calling IPC for transcription...")
                let result = try await ipcClient.stopRecordingAndTranscribe()
                flog("stopRecording: got result, text='\(result.text.prefix(30))'")
                if !result.text.isEmpty {
                    textProxy?.insertText(result.text)
                }
                isTranscribing = false
            } catch {
                flog("stopRecording: IPC FAILED: \(error.localizedDescription)")
                lastError = error.localizedDescription
                isTranscribing = false
            }
        }
    }
}
