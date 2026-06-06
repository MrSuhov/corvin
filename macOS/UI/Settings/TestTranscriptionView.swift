import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct TestTranscriptionView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine

    @State private var resultText = ""
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var errorMessage: String?
    @State private var importedFileName: String?
    @State private var transcribeStartTime: Date?

    // Stored as @State to survive SwiftUI view recreation during re-renders
    @State private var audioCaptureService = AudioCaptureService()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // PTT section
                VStack(spacing: 12) {
                    Text("test.recording.title".localized)
                        .font(.headline)

                    pttButton

                    stateLabel
                }

                Divider()

                // File import section
                VStack(spacing: 12) {
                    Text("test.file.title".localized)
                        .font(.headline)

                    Text("test.file.formats".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            importFile()
                        } label: {
                            Label("test.file.choose".localized, systemImage: "doc.badge.plus")
                        }
                        .modifier(BorderedButtonCompat())
                        .disabled(isRecording || isTranscribing)

                        if let fileName = importedFileName {
                            Text(fileName)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                // Result display
                if !resultText.isEmpty {
                    resultSection
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcribeFileRequest)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                transcribeURL(url)
            }
        }
    }

    private var pttButton: some View {
        PTTCircleButton(
            isRecording: isRecording,
            onMouseDown: { startRecording() },
            onMouseUp: { stopAndTranscribe() }
        )
        .frame(width: 80, height: 80)
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("test.result".localized)
                    .font(.headline)
                Spacer()
                Button("test.copy".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resultText, forType: .string)
                }
                .modifier(BorderedButtonCompat())
            }

            if #available(macOS 12.0, *) {
                Text(resultText)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            } else {
                Text(resultText)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            }
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        if isTranscribing {
            VStack(spacing: 6) {
                if transcriptionEngine.chunkProgress.total > 1 {
                    let cur = transcriptionEngine.chunkProgress.current
                    let tot = transcriptionEngine.chunkProgress.total
                    ProgressView(value: Double(cur), total: Double(tot))
                        .frame(width: 200)
                    Text("Чанк \(cur) из \(tot)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView("status.transcribing".localized)
                }
                if let start = transcribeStartTime {
                    if #available(macOS 13.0, *) {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            let elapsed = Int(context.date.timeIntervalSince(start))
                            Text("\(elapsed) сек.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        } else if isRecording {
            Text("test.recording.holdRelease".localized)
                .foregroundColor(.red)
        } else {
            Text("test.recording.hold".localized)
                .foregroundColor(.secondary)
        }
    }

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
        isRecording = true
        audioCaptureService.startCapture()
    }

    private func importFile() {
        guard !isRecording, !isTranscribing else { return }

        // Prevent concurrent whisper_full() calls with the main hotkey flow
        if case .recording = sessionManager.state { return }
        if case .transcribing = sessionManager.state { return }

        guard modelManager.activeModel != nil else {
            errorMessage = "test.noModel".localized
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio] + [UTType(filenameExtension: "ogg"), UTType(filenameExtension: "opus")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "test.file.chooseMessage".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        transcribeURL(url)
    }

    private func transcribeURL(_ url: URL) {
        guard !isRecording, !isTranscribing else { return }

        // Prevent concurrent whisper_full() calls with the main hotkey flow
        if case .recording = sessionManager.state { return }
        if case .transcribing = sessionManager.state { return }

        guard modelManager.activeModel != nil else {
            errorMessage = "test.noModel".localized
            return
        }

        importedFileName = url.lastPathComponent
        errorMessage = nil
        resultText = ""
        isTranscribing = true
        transcribeStartTime = Date()

        flog("TestView: transcribeURL start: \(url.lastPathComponent)")
        Task {
            do {
                flog("TestView: decoding file...")
                let pcmData = try AudioFileDecoder.decode(url: url)
                flog("TestView: decoded \(pcmData.count) bytes, starting whisper...")
                let result = try await transcriptionEngine.transcribe(audioData: pcmData)
                flog("TestView: transcription done: '\(result.text.prefix(80))'")
                await MainActor.run {
                    resultText = result.text
                    isTranscribing = false
                    transcribeStartTime = nil
                }
            } catch {
                flog("TestView: ERROR \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isTranscribing = false
                    transcribeStartTime = nil
                }
            }
        }
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }
        let audioData = audioCaptureService.stopCapture()
        isRecording = false
        isTranscribing = true
        transcribeStartTime = Date()

        flog("TestView: stopAndTranscribe, \(audioData.count) bytes")
        Task {
            do {
                let result = try await transcriptionEngine.transcribe(audioData: audioData)
                flog("TestView: PTT transcription done: '\(result.text.prefix(80))'")
                await MainActor.run {
                    resultText = result.text
                    isTranscribing = false
                    transcribeStartTime = nil
                }
            } catch {
                flog("TestView: PTT ERROR \(error)")
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
            let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
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
