import SwiftUI

struct ModelManagerView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Row 3: actions
            HStack {
                if model.isDownloaded {
                    if !isActive {
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
                    Button("models.download".localized) {
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

