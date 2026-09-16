import AppKit
import SwiftUI

/// The History tab: everything Corvin has recorded or transcribed, with a card
/// for the selected entry.
struct HistoryFilesView: View {
    @EnvironmentObject var registry: TranscriptRegistry
    @EnvironmentObject var callIndex: CallIndex
    @EnvironmentObject var fileQueue: FileTranscriptionQueue
    @EnvironmentObject var modelManager: ModelManager
    @ObservedObject private var localization = LocalizationManager.shared

    /// Keyed by path rather than index: the list is rebuilt whenever the
    /// registry refreshes its source states.
    @State private var selectedPath: String?

    private var entries: [HistoryEntry] {
        HistoryEntry.merge(records: registry.records, calls: callIndex.calls)
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(localization.currentLanguage)
        .onAppear {
            registry.refreshSourceStates()
            if selectedPath == nil { selectedPath = entries.first?.path }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("history.files.empty".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            HistoryFileRow(entry: entry,
                                           isSelected: entry.path == selectedPath,
                                           isQueued: isQueued(entry),
                                           state: sourceState(entry))
                                .contentShape(Rectangle())
                                .onTapGesture { selectedPath = entry.path }
                        }
                    }
                    .padding(6)
                }
            }

            Divider()

            HStack {
                Text("history.count".localized(with: entries.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("test.history.clear".localized) {
                    registry.removeAll()
                    callIndex.removeAll()
                    selectedPath = nil
                }
                .modifier(BorderedButtonCompat())
                .controlSize(.small)
                .disabled(entries.isEmpty)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = entries.first(where: { $0.path == selectedPath }) {
            HistoryFileDetail(entry: entry,
                              state: sourceState(entry),
                              isQueued: isQueued(entry),
                              onRemove: {
                                  if let record = entry.record { registry.remove(record) }
                                  callIndex.remove(entry.url)
                                  selectedPath = nil
                              })
                // A new entry gets a fresh card: without this the model choice
                // and a pending download confirmation would follow the
                // selection to the next call.
                .id(entry.path)
        } else {
            Text("history.files.empty".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isQueued(_ entry: HistoryEntry) -> Bool {
        fileQueue.jobs.contains { !$0.status.isFinished && $0.url.standardizedFileURL.path == entry.path }
    }

    /// Whether the audio still looks like what was transcribed. Unknown for a
    /// call with no transcript yet, so fall back to plain existence.
    private func sourceState(_ entry: HistoryEntry) -> TranscriptRegistry.SourceState {
        if let record = entry.record,
           let state = registry.state(of: record, .roles) ?? registry.state(of: record, .plain) {
            return state
        }
        return FileManager.default.fileExists(atPath: entry.path) ? .unchanged : .missing
    }
}

// MARK: - Row

struct HistoryFileRow: View {
    let entry: HistoryEntry
    let isSelected: Bool
    let isQueued: Bool
    let state: TranscriptRegistry.SourceState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.appName ?? entry.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isQueued {
                ProgressView()
                    .controlSize(.small)
            }
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

struct HistoryFileDetail: View {
    let entry: HistoryEntry
    let state: TranscriptRegistry.SourceState
    let isQueued: Bool
    let onRemove: () -> Void

    @EnvironmentObject var fileQueue: FileTranscriptionQueue
    @EnvironmentObject var modelManager: ModelManager

    @State private var selectedModelID: String?
    /// Chosen in the picker but not downloaded: nothing happens until the user
    /// says so.
    @State private var pendingDownload: WhisperModel?
    @State private var downloadProgress: Double?
    @State private var downloadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                source
                audio
                transcripts
                retranscribe

                Button("test.history.remove".localized, action: onRemove)
                    .modifier(BorderedButtonCompat())
                    .controlSize(.small)
                    .foregroundColor(.red)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if selectedModelID == nil {
                selectedModelID = entry.variants.compactMap { $0.variant.modelID }.first
                    ?? modelManager.activeModel?.id
            }
        }
    }

    // MARK: Sections

    private var source: some View {
        section("history.files.source".localized) {
            if let app = entry.appName {
                row("history.files.callFrom".localized(with: app), entry.call?.bundleID ?? "")
            }
            row("history.files.recorded".localized, Self.dateFormatter.string(from: entry.date))
            if let duration = entry.duration {
                row("history.files.duration".localized, HistoryEntry.formatDuration(duration))
            }
            row("history.files.file".localized, entry.fileName)
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

    private var retranscribe: some View {
        section("history.files.retranscribe".localized) {
            caption(modeCaption, color: .secondary)

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
                .onChange(of: selectedModelID) { _ in selectionChanged() }

                Button("history.files.retranscribe".localized) {
                    fileQueue.rerun(entry.url, modelID: selectedModelID)
                }
                .modifier(BorderedButtonCompat())
                .controlSize(.small)
                .disabled(state == .missing || isQueued || pendingDownload != nil || downloadProgress != nil)
            }

            if isQueued {
                caption("history.files.queued".localized, color: .secondary)
            }

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

            if let downloadError {
                caption(downloadError, color: .red)
            }
        }
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
                fileQueue.rerun(entry.url, modelID: model.id)
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

    private var modeCaption: String {
        if entry.isCall { return "history.files.mode.call".localized }
        return fileQueue.dialogMode && DiarizationClient.isSupportedSystem
            ? "history.files.mode.roles".localized
            : "history.files.mode.plain".localized
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

/// Reveal and "save a copy", the two things History does with files on disk.
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
            flog("HistoryFiles: copied \(url.lastPathComponent) to \(target.path)")
        } catch {
            flog("HistoryFiles: could not copy \(url.lastPathComponent): \(error)")
        }
    }
}
