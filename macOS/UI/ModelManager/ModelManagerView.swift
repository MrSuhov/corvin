import SwiftUI

struct ModelManagerView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Always reachable. The catalogue is remote, so the list can go stale
            // between launches, and the only other refresh used to sit inside the
            // "new models" banner — which appears only once new models are already
            // known. iOS has pull-to-refresh; this is its counterpart.
            HStack {
                Text("models.available".localized)
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        isRefreshing = true
                        await modelManager.refreshCatalog()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("models.refresh".localized, systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }

            if modelManager.isIntel {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("models.intel.recommendation".localized)
                        .font(.caption)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if !modelManager.unseenModelIDs.isEmpty {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.blue)
                    Text("models.new.banner".localized(with: modelManager.unseenModelIDs.count))
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(modelManager.models) { model in
                        ModelCardView(model: model)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding()
        // Opening the window is the notification; the badge has served its purpose.
        .onAppear { modelManager.markModelsAsSeen() }
    }
}

struct ModelCardView: View {
    let model: WhisperModel
    @EnvironmentObject var modelManager: ModelManager
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var error: String?

    private var isActive: Bool {
        modelManager.activeModel?.id == model.id
    }

    private var isNew: Bool {
        modelManager.unseenModelIDs.contains(model.id)
    }

    /// Downloading an already-installed model is how an update is applied: the file
    /// is verified and replaces the old one in place.
    private func startDownload() {
        isDownloading = true
        error = nil
        modelManager.downloadModel(model, progress: { p in
            downloadProgress = p
        }, completion: { result in
            isDownloading = false
            if case .failure(let err) = result {
                error = err.localizedDescription
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: name + badges
            HStack {
                Text(model.name)
                    .font(.headline)
                if model.recommended {
                    Text("models.recommended".localized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                if isActive {
                    Text("models.active".localized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
                if isNew {
                    Text("models.new.tag".localized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                if let languages = model.languagesLabel {
                    Text(languages)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
            }

            // Row 2: specs
            HStack(spacing: 16) {
                Label(model.size, systemImage: "arrow.down.circle")
                Label(model.ramRequired, systemImage: "memorychip")
                Label("\("models.quality".localized): \(model.quality.localized)", systemImage: "star")
                Label(model.speed, systemImage: "speedometer")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if model.updateAvailable {
                Text("models.update.available".localized)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Row 3: actions
            HStack {
                if model.isDownloaded && !isDownloading {
                    if model.updateAvailable {
                        Button("models.update".localized) { startDownload() }
                            .modifier(ProminentButtonCompat())
                    } else if !isActive {
                        Button("models.select".localized) {
                            modelManager.setActiveModel(model)
                        }
                        .modifier(BorderedButtonCompat())
                    }
                    Spacer()
                    Button(action: { modelManager.deleteModel(model) }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                } else if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView(value: downloadProgress)
                            .frame(width: 120)
                        Button("common.cancel".localized) {
                            modelManager.cancelDownload(model)
                            isDownloading = false
                            downloadProgress = 0
                        }
                        .font(.caption)
                    }
                } else {
                    Button("models.download".localized) { startDownload() }
                        .modifier(ProminentButtonCompat())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.green.opacity(0.5) : Color.clear, lineWidth: 2)
        )
    }
}

