import SwiftUI

struct iOSModelManagerView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("settings.tab.models".localized)) {
                    ForEach(modelManager.models) { model in
                        ModelRow(
                            model: model,
                            isActive: modelManager.activeModel?.id == model.id,
                            isDownloading: modelManager.downloadTasks[model.id] != nil,
                            onDownload: { downloadModel(model) },
                            onActivate: { modelManager.setActiveModel(model) },
                            onDelete: { modelManager.deleteModel(model) }
                        )
                    }
                }
            }
            .navigationTitle("settings.tab.models".localized)
        }
    }

    private func downloadModel(_ model: WhisperModel) {
        modelManager.downloadModel(model, progress: { _ in }, completion: { result in
            if case .success = result, modelManager.activeModel == nil {
                modelManager.setActiveModel(model)
            }
        })
    }
}

struct ModelRow: View {
    let model: WhisperModel
    let isActive: Bool
    let isDownloading: Bool
    let onDownload: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .fontWeight(.medium)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                Text("\(model.size) • \(model.quality.localized) • \(model.speed)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if model.isDownloaded {
                if !isActive {
                    Button("models.select".localized) { onActivate() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if isDownloading {
                ProgressView(value: model.downloadProgress)
                    .frame(width: 60)
            } else {
                Button("models.download".localized) { onDownload() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

