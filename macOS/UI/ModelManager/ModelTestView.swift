import SwiftUI
import AppKit

/// "Try the model": hold the button, speak, release — the active model
/// transcribes it right here, without inserting anything anywhere.
struct ModelTestView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var fileQueue: FileTranscriptionQueue

    @State private var resultText = ""
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var errorMessage: String?
    @State private var transcribeStartTime: Date?

    // Stored as @State to survive SwiftUI view recreation during re-renders
    @State private var audioCaptureService = AudioCaptureService()

    var body: some View {
        HStack(spacing: 12) {
            PTTCircleButton(
                isRecording: isRecording,
                onMouseDown: { startRecording() },
                onMouseUp: { stopAndTranscribe() }
            )
            .frame(width: 48, height: 48)
            .opacity(fileQueue.isRunning ? 0.4 : 1)
            .allowsHitTesting(!fileQueue.isRunning)

            VStack(alignment: .leading, spacing: 4) {
                Text("models.test.title".localized)
                    .font(.headline)
                stateLabel
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stateLabel: some View {
        if isTranscribing {
            VStack(alignment: .leading, spacing: 4) {
                let progress = transcriptionEngine.chunkProgress
                if progress.total > 1 {
                    ProgressView(value: Double(progress.current), total: Double(progress.total))
                        .frame(width: 160)
                    Text("test.status.chunk".localized(with: progress.current, progress.total))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView("status.transcribing".localized)
                }
                if let start = transcribeStartTime {
                    elapsedLabel(since: start)
                }
            }
        } else if isRecording {
            Text("test.recording.holdRelease".localized)
                .font(.caption)
                .foregroundColor(.red)
        } else if !resultText.isEmpty {
            HStack(spacing: 8) {
                Text(resultText)
                    .font(.caption)
                    .lineLimit(2)
                Button("test.copy".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resultText, forType: .string)
                }
                .modifier(BorderedButtonCompat())
            }
        } else {
            Text("test.recording.hold".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func elapsedLabel(since start: Date) -> some View {
        if #available(macOS 13.0, *) {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text("test.elapsed".localized(with: Int(context.date.timeIntervalSince(start))))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Push-to-talk plumbing

    private func startRecording() {
        guard !isRecording, !isTranscribing else { return }

        // Prevent concurrent whisper_full() calls with the main hotkey flow
        if case .recording = sessionManager.state { return }
        if case .transcribing = sessionManager.state { return }

        guard modelManager.activeModel != nil else {
            errorMessage = "test.noModel".localized
            return
        }

        errorMessage = nil
        resultText = ""
        isRecording = true
        audioCaptureService.startCapture()
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }
        let audioData = audioCaptureService.stopCapture()
        isRecording = false
        isTranscribing = true
        transcribeStartTime = Date()

        flog("ModelTest: stopAndTranscribe, \(audioData.count) bytes")
        Task {
            do {
                let result = try await transcriptionEngine.transcribe(audioData: audioData)
                flog("ModelTest: PTT transcription done: '\(result.text.prefix(80))'")
                await MainActor.run {
                    resultText = result.text
                    isTranscribing = false
                    transcribeStartTime = nil
                }
            } catch {
                flog("ModelTest: PTT ERROR \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isTranscribing = false
                    transcribeStartTime = nil
                }
            }
        }
    }
}

// MARK: - PTT Button using NSViewRepresentable for mouse down/up

struct PTTCircleButton: NSViewRepresentable {
    let isRecording: Bool
    let onMouseDown: () -> Void
    let onMouseUp: () -> Void

    func makeNSView(context: Context) -> PTTCircleNSView {
        let view = PTTCircleNSView()
        view.onMouseDown = onMouseDown
        view.onMouseUp = onMouseUp
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: PTTCircleNSView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseUp = onMouseUp
        nsView.isRecording = isRecording
        nsView.needsDisplay = true
    }
}

class PTTCircleNSView: NSView {
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var isPressed = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(ovalIn: rect)

        // Fill color
        let fillColor: NSColor = isRecording ? .systemRed : .systemBlue
        fillColor.setFill()
        path.fill()

        // Shadow effect
        let shadow = NSShadow()
        shadow.shadowColor = (isRecording ? NSColor.systemRed : NSColor.systemBlue).withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        // Icon
        let iconName = isRecording ? "stop.fill" : "mic.fill"
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            let configured = image.withSymbolConfiguration(config) ?? image
            let imageSize = configured.size
            let imageRect = NSRect(
                x: (bounds.width - imageSize.width) / 2,
                y: (bounds.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            NSColor.white.set()
            configured.draw(in: imageRect, from: .zero, operation: .sourceAtop, fraction: 1.0)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onMouseDown?()
    }

    override func mouseUp(with event: NSEvent) {
        if isPressed {
            isPressed = false
            onMouseUp?()
        }
    }
}
