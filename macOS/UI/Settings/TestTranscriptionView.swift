import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct TestTranscriptionView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @EnvironmentObject var fileQueue: FileTranscriptionQueue
    @EnvironmentObject var diarizationModels: DiarizationModelStore
    @EnvironmentObject var registry: TranscriptRegistry
    @EnvironmentObject var vocabularies: VocabularyStore

    @State private var isEditingVocabularies = false

    @State private var resultText = ""
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var errorMessage: String?
    @State private var transcribeStartTime: Date?
    @State private var isDropTargeted = false

    // Stored as @State to survive SwiftUI view recreation during re-renders
    @State private var audioCaptureService = AudioCaptureService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pttSection

                Divider()

                fileSection

                if !fileQueue.jobs.isEmpty {
                    Divider()
                    queueSection
                }

                if !registry.records.isEmpty {
                    Divider()
                    historySection
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            diarizationModels.refresh()
            registry.refreshSourceStates()
        }
        // The whole pane is the drop target, not a separate well.
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(2)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Push to talk

    private var pttSection: some View {
        HStack(spacing: 12) {
            PTTCircleButton(
                isRecording: isRecording,
                onMouseDown: { startRecording() },
                onMouseUp: { stopAndTranscribe() }
            )
            .frame(width: 56, height: 56)
            .opacity(fileQueue.isRunning ? 0.4 : 1)
            .allowsHitTesting(!fileQueue.isRunning)

            VStack(alignment: .leading, spacing: 4) {
                Text("test.recording.title".localized)
                    .font(.headline)
                stateLabel
            }
            Spacer()
        }
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

    // MARK: - File import

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("test.file.title".localized)
                .font(.headline)

            HStack(spacing: 6) {
                Text("test.output.label".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(outputDirectoryLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("test.output.choose".localized) { fileQueue.chooseOutputDirectory() }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
                if fileQueue.outputDirectory != nil {
                    Button {
                        fileQueue.clearOutputDirectory()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("test.output.reset".localized)
                }
            }

            HStack(spacing: 10) {
                Button {
                    importFiles()
                } label: {
                    Label("test.file.choose".localized, systemImage: "doc.badge.plus")
                }
                .modifier(BorderedButtonCompat())

                Text("test.file.dropHint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("test.file.formats".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            dialogSection

            vocabularySection

            if !fileQueue.blockedDirectories.isEmpty {
                blockedBanner
            }
        }
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        HStack(spacing: 8) {
            Text("test.vocabulary.label".localized)
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("test.vocabulary.label".localized, selection: $vocabularies.activeID) {
                Text("test.vocabulary.none".localized).tag(UUID?.none)
                ForEach(vocabularies.vocabularies) { vocabulary in
                    Text(vocabulary.name).tag(UUID?.some(vocabulary.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            Button("test.vocabulary.edit".localized) { isEditingVocabularies = true }
                .modifier(BorderedButtonCompat())
                .controlSize(.small)
        }
        .sheet(isPresented: $isEditingVocabularies) {
            VocabularyEditorView()
                .environmentObject(vocabularies)
                .environmentObject(transcriptionEngine)
        }
    }

    // MARK: - Dialog mode

    private var dialogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("test.dialog.toggle".localized, isOn: $fileQueue.dialogMode)
                .disabled(!DiarizationClient.isSupportedSystem)

            if !DiarizationClient.isSupportedSystem {
                secondaryCaption("test.dialog.requiresMacOS14".localized)
            } else if fileQueue.dialogMode {
                dialogModelsStatus
            } else {
                secondaryCaption("test.dialog.hint".localized)
            }
        }
    }

    @ViewBuilder
    private var dialogModelsStatus: some View {
        if let progress = diarizationModels.progress {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 120)
                secondaryCaption("test.dialog.downloading".localized)
                Button("test.dialog.cancel".localized) { diarizationModels.cancel() }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
        } else if !diarizationModels.isInstalled {
            HStack(spacing: 8) {
                secondaryCaption("test.dialog.modelsNeeded".localized(with: modelsSizeLabel))
                Button("test.dialog.download".localized) { Task { await diarizationModels.install() } }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
        } else if diarizationModels.updateAvailable {
            HStack(spacing: 8) {
                secondaryCaption("test.dialog.updateAvailable".localized)
                Button("test.dialog.update".localized) { Task { await diarizationModels.install() } }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
        } else {
            secondaryCaption("test.dialog.hint".localized)
        }

        if let error = diarizationModels.error {
            Text(error.text)
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelsSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: diarizationModels.currentEntry.sizeBytes, countStyle: .file)
    }

    private func secondaryCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var outputDirectoryLabel: String {
        guard let directory = fileQueue.outputDirectory else {
            return "test.output.nextToAudio".localized
        }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    private var blockedBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("test.perm.banner".localized(with: fileQueue.blockedDirectories.count))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("test.queue.summary".localized(with: fileQueue.finishedCount, fileQueue.jobs.count))
                    .font(.headline)
                Spacer()
                if fileQueue.isRunning {
                    Button("test.queue.stop".localized) { fileQueue.requestStop() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                        .disabled(fileQueue.abortRequested)
                }
                if !fileQueue.unsavedJobs.isEmpty {
                    Button("test.queue.saveAll".localized) { fileQueue.saveAllUnsaved() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
                if fileQueue.hasFinishedJobs {
                    Button("test.queue.clear".localized) { fileQueue.clearFinished() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
            }

            if fileQueue.stopRequested {
                Text((fileQueue.abortRequested ? "test.queue.aborting" : "test.queue.stopping").localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(fileQueue.jobs) { job in
                    JobRow(job: job,
                           onReveal: { reveal(job) },
                           onSaveAs: { fileQueue.saveAs(jobID: job.id) },
                           onRestart: { fileQueue.stopAndRestart(job.id) })
                }
            }
        }
    }

    // MARK: - Transcribed files

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("test.history.title".localized)
                    .font(.headline)
                Spacer()
                Button("test.history.clear".localized) { registry.removeAll() }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }

            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(registry.records) { record in
                    RecordRow(record: record,
                              plainState: registry.state(of: record, .plain),
                              rolesState: registry.state(of: record, .roles),
                              isQueued: fileQueue.jobs.contains {
                                  !$0.status.isFinished && $0.url.standardizedFileURL.path == record.sourcePath
                              },
                              onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                              onRerun: { fileQueue.rerun(record.sourceURL) },
                              onRemove: { registry.remove(record) })
                }
            }
        }
    }

    private func reveal(_ job: FileTranscriptionQueue.Job) {
        guard let url = job.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let identifier = UTType.fileURL.identifier
        let group = DispatchGroup()
        let lock = NSLock()
        // Keyed by index so the queue ends up in the order they were dragged,
        // not in whatever order the async loads happen to finish.
        var collected: [Int: URL] = [:]

        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                defer { group.leave() }
                // Finder vends any of these three shapes depending on the OS
                // version; `loadObject(ofClass: URL.self)` is not dependable
                // before macOS 13.
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? NSURL {
                    url = nsurl as URL
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url else { return }
                lock.lock()
                collected[index] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let urls = collected.sorted { $0.key < $1.key }.map { $0.value }
            guard !urls.isEmpty else { return }
            // LSUIElement app: the permission alert and open panels need us
            // frontmost or they open behind whatever the user dragged from.
            NSApp.activate(ignoringOtherApps: true)
            fileQueue.enqueue(urls: urls)
        }

        // Claim the drop now; the loads finish on their own.
        return true
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
            + AudioFileDecoder.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "test.file.chooseMessage".localized

        guard panel.runModal() == .OK else { return }
        fileQueue.enqueue(urls: panel.urls)
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

// MARK: - Queue row

private struct JobRow: View {
    let job: FileTranscriptionQueue.Job
    let onReveal: () -> Void
    let onSaveAs: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 14)

            Text(job.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 90, alignment: .leading)
                .layoutPriority(1)

            if job.mode == .roles {
                ModeBadge(title: "test.history.badge.roles".localized, highlighted: false)
            }

            detail

            Spacer(minLength: 0)

            if !job.status.isFinished {
                Button(action: onRestart) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .help("test.queue.restart".localized)
            }

            if job.outputURL != nil {
                Button(action: onReveal) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .help("test.queue.reveal".localized)
            } else if job.status == .failed, job.text?.isEmpty == false {
                Button("test.queue.saveAs".localized, action: onSaveAs)
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch job.status {
        case .pending:
            caption("test.status.pending".localized)
        case .waitingForMic:
            caption("test.status.waitingMic".localized)
        case .decoding:
            caption("test.status.decoding".localized)
        case .diarizing:
            HStack(spacing: 6) {
                if job.progress.total > 1 {
                    ProgressView(value: Double(job.progress.current), total: Double(job.progress.total))
                        .frame(width: 60)
                }
                caption("test.status.diarizing".localized)
            }
        case .transcribing:
            HStack(spacing: 6) {
                if job.progress.total > 1 {
                    ProgressView(value: Double(job.progress.current), total: Double(job.progress.total))
                        .frame(width: 60)
                    caption("test.status.chunk".localized(with: job.progress.current, job.progress.total))
                } else {
                    caption("status.transcribing".localized)
                }
            }
        case .saved:
            caption(job.outputURL?.lastPathComponent ?? "")
        case .savedToFallback:
            caption("test.status.fallback".localized)
        case .empty:
            caption("test.status.empty".localized)
        case .cancelled:
            caption("test.status.cancelled".localized)
        case .failed:
            Text(job.error ?? "test.status.failed".localized)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var iconName: String {
        switch job.status {
        case .pending, .waitingForMic: return "clock"
        case .decoding, .diarizing, .transcribing: return "waveform"
        case .saved: return "checkmark.circle.fill"
        case .savedToFallback: return "exclamationmark.circle.fill"
        case .empty: return "minus.circle"
        case .cancelled: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch job.status {
        case .saved: return .green
        case .savedToFallback: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Transcribed file row

private struct RecordRow: View {
    let record: TranscriptRegistry.Record
    let plainState: TranscriptRegistry.SourceState?
    let rolesState: TranscriptRegistry.SourceState?
    let isQueued: Bool
    let onReveal: (URL) -> Void
    let onRerun: () -> Void
    let onRemove: () -> Void

    private var isMissing: Bool { plainState == .missing || rolesState == .missing }
    private var isChanged: Bool { plainState == .changed || rolesState == .changed }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMissing ? "questionmark.circle" : isChanged ? "exclamationmark.triangle.fill" : "doc.text")
                .foregroundColor(isChanged ? .orange : .secondary)
                .frame(width: 14)

            Text(record.sourceURL.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 90, alignment: .leading)
                .layoutPriority(1)
                .help(record.sourcePath)

            if let plain = record.plain {
                badge("test.history.badge.plain".localized, plain, plainState)
            }
            if let roles = record.roles {
                badge("test.history.badge.roles".localized, roles, rolesState)
            }

            if isMissing {
                Text("test.history.missing".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if isChanged {
                Text("test.history.changed".localized)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onRerun) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isMissing || isQueued)
            .help("test.history.rerun".localized)

            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("test.history.remove".localized)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.orange.opacity(isChanged ? 0.15 : 0))
        )
    }

    /// Opens the transcript in Finder; orange when the audio changed after it
    /// was made.
    private func badge(_ title: String, _ variant: TranscriptRegistry.Variant,
                       _ state: TranscriptRegistry.SourceState?) -> some View {
        Button { onReveal(variant.outputURL) } label: {
            ModeBadge(title: title, highlighted: state == .changed)
        }
        .buttonStyle(.plain)
        .help(variant.outputURL.lastPathComponent)
    }
}

private struct ModeBadge: View {
    let title: String
    let highlighted: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundColor(highlighted ? .orange : .secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(highlighted ? Color.orange : Color.secondary, lineWidth: 1)
            )
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
