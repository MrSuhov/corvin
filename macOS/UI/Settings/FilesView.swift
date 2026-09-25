import AppKit
import SwiftUI

/// The Files tab: everything Corvin has recorded, transcribed or is
/// transcribing, with a card for the selected file. Files are added here, by a
/// drop on any tab, or from Finder; the card is the one place to choose how a
/// file is transcribed.
struct FilesView: View {
    @ObservedObject var selection: SettingsTabSelection

    @EnvironmentObject var registry: TranscriptRegistry
    @EnvironmentObject var callIndex: CallIndex
    @EnvironmentObject var fileQueue: FileTranscriptionQueue
    @EnvironmentObject var vocabularies: VocabularyStore
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var isEditingVocabularies = false

    private var entries: [HistoryEntry] {
        HistoryEntry.merge(records: registry.records, calls: callIndex.calls, jobs: fileQueue.jobs)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(localization.currentLanguage)
        .onAppear {
            registry.refreshSourceStates()
            if selection.filePath == nil { selection.filePath = entries.first?.path }
        }
    }

    // MARK: - Toolbar

    /// Adding files, and where their transcripts go.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                Button {
                    selection.show(added: fileQueue.enqueue(urls: AudioFileImport.chooseFiles()))
                } label: {
                    Label("files.add".localized, systemImage: "plus")
                }
                .modifier(BorderedButtonCompat())

                Divider()
                    .frame(height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    outputRow
                    vocabularyRow
                }
                Spacer(minLength: 0)
            }

            if !fileQueue.blockedDirectories.isEmpty {
                blockedBanner
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var outputRow: some View {
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
    }

    private var vocabularyRow: some View {
        HStack(spacing: 6) {
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
            .controlSize(.small)
            .frame(maxWidth: 200)
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

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("files.empty".localized)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Text("test.file.formats".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            FileRow(entry: entry,
                                    isSelected: entry.path == selection.filePath,
                                    state: sourceState(entry))
                                .contentShape(Rectangle())
                                .onTapGesture { selection.filePath = entry.path }
                        }
                    }
                    .padding(6)
                }
            }

            Divider()
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if fileQueue.stopRequested {
                Text((fileQueue.abortRequested ? "test.queue.aborting" : "test.queue.stopping").localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("history.count".localized(with: entries.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if fileQueue.isRunning {
                    Button("files.stopAll".localized) { fileQueue.requestStop() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                        .disabled(fileQueue.abortRequested)
                }
                if !fileQueue.unsavedJobs.isEmpty {
                    Button("test.queue.saveAll".localized) { fileQueue.saveAllUnsaved() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
                Button("test.history.clear".localized) {
                    registry.removeAll()
                    callIndex.removeAll()
                    fileQueue.clearFinished()
                    selection.filePath = nil
                }
                .modifier(BorderedButtonCompat())
                .controlSize(.small)
                .disabled(entries.allSatisfy { $0.isQueued })
            }
        }
        .padding(8)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = entries.first(where: { $0.path == selection.filePath }) {
            FileDetail(entry: entry,
                       state: sourceState(entry),
                       onRemove: {
                           if let record = entry.record { registry.remove(record) }
                           callIndex.remove(entry.url)
                           fileQueue.forgetFinished(entry.url)
                           selection.filePath = nil
                       })
                // A new entry gets a fresh card: without this the mode and
                // model choice and a pending download confirmation would follow
                // the selection to the next file.
                .id(entry.path)
        } else {
            Text((entries.isEmpty ? "files.empty" : "files.select").localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether the audio still looks like what was transcribed. Unknown for a
    /// file with no transcript yet, so fall back to plain existence.
    private func sourceState(_ entry: HistoryEntry) -> TranscriptRegistry.SourceState {
        if let record = entry.record,
           let state = registry.state(of: record, .roles) ?? registry.state(of: record, .plain) {
            return state
        }
        return FileManager.default.fileExists(atPath: entry.path) ? .unchanged : .missing
    }
}

// MARK: - Job status

/// How a job reads in the list and on the card.
extension FileTranscriptionQueue.Job {

    /// The job should be shown instead of the file's usual icon and subtitle:
    /// it is under way, or its last attempt did not produce a transcript.
    var isNoteworthy: Bool {
        switch status {
        case .saved: return false
        default: return true
        }
    }

    var statusText: String {
        switch status {
        case .pending: return "test.status.pending".localized
        case .waitingForMic: return "test.status.waitingMic".localized
        case .decoding: return "test.status.decoding".localized
        case .diarizing: return "test.status.diarizing".localized
        case .transcribing:
            return progress.total > 1
                ? "test.status.chunk".localized(with: progress.current, progress.total)
                : "status.transcribing".localized
        case .saved: return outputURL?.lastPathComponent ?? ""
        case .savedToFallback: return "test.status.fallback".localized
        case .empty: return "test.status.empty".localized
        case .cancelled: return "test.status.cancelled".localized
        case .failed: return error ?? "test.status.failed".localized
        }
    }

    var statusIcon: String {
        switch status {
        case .pending, .waitingForMic: return "clock"
        case .decoding, .diarizing, .transcribing: return "waveform"
        case .saved: return "checkmark.circle.fill"
        case .savedToFallback: return "exclamationmark.circle.fill"
        case .empty: return "minus.circle"
        case .cancelled: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch status {
        case .decoding, .diarizing, .transcribing: return .accentColor
        case .saved: return .green
        case .savedToFallback: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    /// A share of the work, when there is one to show.
    var fraction: Double? {
        guard !status.isFinished, progress.total > 1 else { return nil }
        return Double(progress.current) / Double(progress.total)
    }
}

// MARK: - Row

struct FileRow: View {
    let entry: HistoryEntry
    let isSelected: Bool
    let state: TranscriptRegistry.SourceState

    private var job: FileTranscriptionQueue.Job? {
        entry.job.flatMap { $0.isNoteworthy ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: job?.statusIcon ?? icon)
                .foregroundColor(job?.statusColor ?? iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.appName ?? entry.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = job?.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(job?.statusText ?? subtitle)
                    .font(.caption2)
                    .foregroundColor(job?.status == .failed ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
    }

    private var icon: String {
        switch state {
        case .missing: return "questionmark.circle"
        case .changed: return "exclamationmark.triangle.fill"
        case .unchanged: return entry.isCall ? "phone.fill" : "doc.text"
        }
    }

    private var iconColor: Color {
        switch state {
        case .missing: return .secondary
        case .changed: return .orange
        case .unchanged: return .accentColor
        }
    }

    private var subtitle: String {
        var parts: [String] = [Self.dateFormatter.string(from: entry.date)]
        if let duration = entry.duration {
            parts.append(HistoryEntry.formatDuration(duration))
        }
        if entry.appName != nil { parts.append(entry.fileName) }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Detail card

struct FileDetail: View {
    let entry: HistoryEntry
    let state: TranscriptRegistry.SourceState
    let onRemove: () -> Void

    @EnvironmentObject var fileQueue: FileTranscriptionQueue
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var diarizationModels: DiarizationModelStore
    @EnvironmentObject var vocabularies: VocabularyStore

    @State private var mode: TranscriptMode = .plain
    @State private var selectedModelID: String?
    /// Chosen in the picker but not downloaded: nothing happens until the user
    /// says so.
    @State private var pendingDownload: WhisperModel?
    @State private var downloadProgress: Double?
    @State private var downloadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                recognition
                transcripts
                audio

                Button("test.history.remove".localized, action: onRemove)
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
                    .foregroundColor(.red)
                    .disabled(entry.isQueued)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            diarizationModels.refresh()
            mode = initialMode
            if selectedModelID == nil {
                selectedModelID = initialModelID
            }
        }
    }

    // MARK: Choice the card opens with

    /// What this file was last transcribed as, else the last choice anywhere.
    private var initialMode: TranscriptMode {
        if let job = entry.job, job.mode != .call { return job.mode }
        let latest = entry.variants.filter { $0.mode != .call }.max { $0.variant.date < $1.variant.date }
        return latest?.mode ?? fileQueue.currentMode
    }

    private var initialModelID: String? {
        if let job = entry.job, let id = job.modelID { return id }
        let latest = entry.variants.max { $0.variant.date < $1.variant.date }
        return latest?.variant.modelID
            ?? fileQueue.currentModelID
            ?? modelManager.activeModel?.id
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.appName.map { "history.files.callFrom".localized(with: $0) } ?? entry.fileName)
                .font(.title3)
                .lineLimit(2)
                .truncationMode(.middle)
            if entry.call != nil || entry.record != nil {
                row("history.files.recorded".localized, Self.dateFormatter.string(from: entry.date))
            }
            if let duration = entry.duration {
                row("history.files.duration".localized, HistoryEntry.formatDuration(duration))
            }
            if entry.appName != nil {
                row("history.files.file".localized, entry.fileName)
            }
            switch state {
            case .changed:
                caption("test.history.changed".localized, color: .orange)
            case .missing:
                caption("test.history.missing".localized, color: .orange)
            case .unchanged:
                EmptyView()
            }
            if entry.call?.recoveredAfterCrash == true {
                caption("history.files.recovered".localized, color: .secondary)
            }
        }
    }

    /// The one place to choose how a file is transcribed. The choice also
    /// becomes the default for files added next.
    private var recognition: some View {
        section("files.recognition".localized) {
            if entry.isCall {
                caption("history.files.mode.call".localized, color: .secondary)
            } else {
                Picker("", selection: $mode) {
                    Text("files.mode.plain".localized).tag(TranscriptMode.plain)
                    Text("files.mode.roles".localized).tag(TranscriptMode.roles)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(!DiarizationClient.isSupportedSystem || entry.isQueued)

                if !DiarizationClient.isSupportedSystem {
                    caption("test.dialog.requiresMacOS14".localized, color: .secondary)
                } else {
                    caption((mode == .roles ? "test.dialog.hint" : "files.mode.plain.hint").localized,
                            color: .secondary)
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: $selectedModelID) {
                    ForEach(modelManager.models) { model in
                        Label {
                            Text("\(model.name) · \(model.size)")
                        } icon: {
                            Image(systemName: model.isDownloaded ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                        }
                        .tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(entry.isQueued)
                .onChange(of: selectedModelID) { _ in selectionChanged() }

                if let job = entry.job, entry.isQueued {
                    Button("files.stop".localized) { fileQueue.cancel(job.id) }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                } else {
                    Button((entry.variants.isEmpty && entry.job == nil
                            ? "files.transcribe" : "history.files.retranscribe").localized) {
                        fileQueue.rerun(entry.url, mode: runMode, modelID: selectedModelID)
                    }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
                    .disabled(!canRun)
                }
            }

            if let job = entry.job, job.isNoteworthy {
                jobStatus(job)
            }

            if mode == .roles, !entry.isCall, !entry.isQueued {
                DiarizationModelsStatusView()
            }

            modelDownload

            // The dictionary is chosen above the list, for every file; say
            // when this file's model is going to ignore it.
            if vocabularies.activeID != nil,
               let model = modelManager.models.first(where: { $0.id == selectedModelID }),
               !model.supportsPrompt {
                caption("files.vocabulary.unsupported".localized, color: .secondary)
            }

            if let downloadError {
                caption(downloadError, color: .red)
            }

            if !entry.isCall, DiarizationClient.isSupportedSystem {
                caption("files.defaults.hint".localized, color: .secondary)
            }
        }
    }

    private func jobStatus(_ job: FileTranscriptionQueue.Job) -> some View {
        HStack(spacing: 8) {
            Image(systemName: job.statusIcon)
                .foregroundColor(job.statusColor)
            if let fraction = job.fraction {
                ProgressView(value: fraction)
                    .frame(width: 120)
            }
            Text(job.statusText)
                .font(.caption)
                .foregroundColor(job.status == .failed ? .red : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if job.status == .failed, job.text?.isEmpty == false {
                Button("test.queue.saveAs".localized) { fileQueue.saveAs(jobID: job.id) }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var modelDownload: some View {
        if let progress = downloadProgress, let model = pendingDownload {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text("history.files.model.downloading".localized(with: model.name))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("common.cancel".localized) {
                    modelManager.cancelDownload(model)
                    downloadProgress = nil
                    restoreSelection()
                }
                .modifier(BorderedButtonCompat())
                .controlSize(.small)
            }
        } else if let model = pendingDownload {
            VStack(alignment: .leading, spacing: 6) {
                Text("history.files.model.notDownloaded".localized(with: model.name, model.size))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("history.files.model.download".localized) { startDownload(model) }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                    Button("common.cancel".localized) { restoreSelection() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
        }
    }

    private var transcripts: some View {
        section("history.files.transcripts".localized) {
            if entry.variants.isEmpty {
                caption("history.files.noTranscripts".localized, color: .secondary)
            } else {
                ForEach(entry.variants, id: \.mode) { item in
                    transcriptRow(mode: item.mode, variant: item.variant)
                }
            }
        }
    }

    private func transcriptRow(mode: TranscriptMode, variant: TranscriptRegistry.Variant) -> some View {
        let exists = FileManager.default.fileExists(atPath: variant.outputPath)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Self.badge(mode))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(3)
                Text(Self.dateFormatter.string(from: variant.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
                Button("history.files.saveAs".localized) { FileActions.saveCopy(of: variant.outputURL) }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
                Button("history.files.reveal".localized) { FileActions.reveal(variant.outputURL) }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
            .disabled(!exists)

            HStack(spacing: 10) {
                if let modelID = variant.modelID {
                    caption("history.files.model".localized + ": " + modelName(modelID), color: .secondary)
                }
                if let dictionary = variant.dictionaryName {
                    caption("history.files.dictionary".localized + ": " + dictionary, color: .secondary)
                }
            }
            if !exists {
                caption("history.files.transcriptMissing".localized, color: .orange)
            }
        }
    }

    private var audio: some View {
        section("history.files.audio".localized) {
            HStack(spacing: 8) {
                Button("history.files.saveAs".localized) { FileActions.saveCopy(of: entry.url) }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
                Button("history.files.reveal".localized) { FileActions.reveal(entry.url) }
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
            }
            .disabled(state == .missing)
        }
    }

    // MARK: Running

    /// A call is transcribed as a call whatever the segment says: its channels
    /// are what tell the speakers apart.
    private var runMode: TranscriptMode {
        if entry.isCall { return .call }
        return mode == .roles && DiarizationClient.isSupportedSystem ? .roles : .plain
    }

    private var canRun: Bool {
        guard state != .missing, pendingDownload == nil, downloadProgress == nil else { return false }
        // Without the speaker models the job would only fail; the card offers
        // the download instead.
        if runMode == .roles, !diarizationModels.isInstalled { return false }
        return true
    }

    // MARK: Model choice

    /// The picker only offers; downloading is a separate, explicit step.
    private func selectionChanged() {
        downloadError = nil
        guard let id = selectedModelID,
              let model = modelManager.models.first(where: { $0.id == id }) else {
            pendingDownload = nil
            return
        }
        pendingDownload = model.isDownloaded ? nil : model
    }

    private func startDownload(_ model: WhisperModel) {
        downloadProgress = 0
        downloadError = nil
        modelManager.downloadModel(model, progress: { progress in
            downloadProgress = progress
        }, completion: { result in
            downloadProgress = nil
            switch result {
            case .success:
                pendingDownload = nil
                if canRun {
                    fileQueue.rerun(entry.url, mode: runMode, modelID: model.id)
                }
            case .failure(let error):
                downloadError = error.localizedDescription
                restoreSelection()
            }
        })
    }

    /// Back to a model that is actually on disk, so the button is usable again.
    private func restoreSelection() {
        pendingDownload = nil
        selectedModelID = modelManager.activeModel?.id
            ?? modelManager.models.first(where: { $0.isDownloaded })?.id
    }

    private func modelName(_ id: String) -> String {
        modelManager.models.first { $0.id == id }?.name ?? id
    }

    private static func badge(_ mode: TranscriptMode) -> String {
        switch mode {
        case .plain: return "test.history.badge.plain".localized
        case .roles: return "test.history.badge.roles".localized
        case .call: return "history.files.badge.call".localized
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Speaker models

/// The speaker recognition models, when they need attention: missing, being
/// downloaded, or with an update. Nothing when they are in order.
struct DiarizationModelsStatusView: View {
    @EnvironmentObject var diarizationModels: DiarizationModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = diarizationModels.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    caption("test.dialog.downloading".localized)
                    Button("test.dialog.cancel".localized) { diarizationModels.cancel() }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
            } else if !diarizationModels.isInstalled {
                HStack(spacing: 8) {
                    caption("test.dialog.modelsNeeded".localized(with: sizeLabel))
                    Button("test.dialog.download".localized) { Task { await diarizationModels.install() } }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
            } else if diarizationModels.updateAvailable {
                HStack(spacing: 8) {
                    caption("test.dialog.updateAvailable".localized)
                    Button("test.dialog.update".localized) { Task { await diarizationModels.install() } }
                        .modifier(BorderedButtonCompat())
                        .controlSize(.small)
                }
            }

            if let error = diarizationModels.error {
                Text(error.text)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: diarizationModels.currentEntry.sizeBytes, countStyle: .file)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reveal and "save a copy", the two things Files does with files on disk.
enum FileActions {

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// A copy rather than a move: the original stays where Corvin put it, and
    /// the registry keeps pointing at something real.
    static func saveCopy(of url: URL) {
        // LSUIElement app: without this the panel opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            flog("Files: copied \(url.lastPathComponent) to \(target.path)")
        } catch {
            flog("Files: could not copy \(url.lastPathComponent): \(error)")
        }
    }
}
