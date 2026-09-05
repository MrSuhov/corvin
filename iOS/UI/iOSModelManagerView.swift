import SwiftUI

struct iOSModelManagerView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        NavigationView {
            List {
                if !modelManager.unseenModelIDs.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.blue)
                            Text(String(format: "models.new.banner".localized, modelManager.unseenModelIDs.count))
                                .font(.subheadline)
                        }
                    }
                }

                Section(header: Text("settings.tab.models".localized)) {
                    ForEach(modelManager.models) { model in
                        ModelRow(
                            model: model,
                            isActive: modelManager.activeModel?.id == model.id,
                            isDownloading: modelManager.downloadTasks[model.id] != nil,
                            isNew: modelManager.unseenModelIDs.contains(model.id),
                            onDownload: { downloadModel(model) },
                            onActivate: { modelManager.setActiveModel(model) },
                            onDelete: { modelManager.deleteModel(model) }
                        )
                    }
                }
            }
            .navigationTitle("settings.tab.models".localized)
            .refreshable { await modelManager.refreshCatalog() }
            // Seeing the list is what clears the badge — the user has now been told.
            .onAppear { modelManager.markModelsAsSeen() }
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
    var isNew: Bool = false
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
                    if isNew {
                        Text("models.new.tag".localized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                }
                Text("\(model.size) • \(model.quality.localized) • \(model.speed)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if model.updateAvailable {
                    Text("models.update.available".localized)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            if isDownloading {
                ProgressView(value: model.downloadProgress)
                    .frame(width: 60)
            } else if model.isDownloaded {
                // An outdated copy still works, so updating is offered rather than
                // forced — these files run to gigabytes.
                if model.updateAvailable {
                    Button("models.update".localized) { onDownload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if !isActive {
                    Button("models.select".localized) { onActivate() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("models.download".localized) { onDownload() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
