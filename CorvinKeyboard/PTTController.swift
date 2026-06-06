import Foundation
import UIKit
import Combine

class PTTController: ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?
    @Published var isTranscribing = false

    private let ipcClient = IPCClient()
    private weak var textProxy: UITextDocumentProxy?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var ipcStartSucceeded = false
    private var startRecordingTask: Task<Void, Never>?

    init(textDocumentProxy: UITextDocumentProxy) {
        self.textProxy = textDocumentProxy
    }

    func startRecording() {
        flog("startRecording called, isRecording=\(isRecording)")
        guard !isRecording else {
            flog("startRecording: already recording, ignoring")
            return
        }

        lastError = nil
        isRecording = true
        ipcStartSucceeded = false
        recordingStartTime = Date()

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }

        // Tell host app to start recording
        startRecordingTask = Task { @MainActor in
            do {
                flog("startRecording: calling IPC...")
                try await ipcClient.startRecording()
                flog("startRecording: IPC success")
                ipcStartSucceeded = true
            } catch {
                if Task.isCancelled { return }
                flog("startRecording: IPC FAILED: \(error.localizedDescription)")
                lastError = error.localizedDescription
                isRecording = false
                recordingTimer?.invalidate()
                recordingTimer = nil
                return
            }
        }

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    func stopRecording() {
        flog("stopRecording called, isRecording=\(isRecording)")
        guard isRecording else {
            flog("stopRecording: not recording, ignoring")
            return
        }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        flog("stopRecording: duration=\(String(format: "%.2f", duration))s")

        isRecording = false
        startRecordingTask?.cancel()
        startRecordingTask = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
        recordingStartTime = nil

        // If IPC start never succeeded, don't try to stop/transcribe
        guard ipcStartSucceeded else {
            flog("stopRecording: IPC start not confirmed, skipping transcription")
            lastError = "Не удалось начать запись"
            return
        }

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

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}
