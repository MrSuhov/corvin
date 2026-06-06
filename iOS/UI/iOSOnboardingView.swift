import SwiftUI
import AVFoundation

struct iOSOnboardingView: View {
    @EnvironmentObject var modelManager: ModelManager
    @AppStorage("onboardingStep", store: UserDefaults(suiteName: "group.com.corvinvoice.app"))
    private var step = 0
    @State private var micGranted = false
    @State private var selectedModelId: String?
    let onComplete: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                TabView(selection: $step) {
                    welcomeStep.tag(0)
                    microphoneStep.tag(1)
                    modelStep.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .animation(.easeInOut, value: step)
            }
            .navigationTitle("Настройка Corvin")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Check mic permission on appear (user may have granted in Settings)
                micGranted = AVAudioSession.sharedInstance().recordPermission == .granted
            }
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Добро пожаловать в Corvin")
                .font(.title2.bold())
            Text("Речь в текст прямо с клавиатуры.\nНажмите и говорите — текст появится мгновенно.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Spacer()
            Button("Далее") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
        }
        .padding()
    }

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: micGranted ? "mic.fill" : "mic.slash")
                .font(.system(size: 60))
                .foregroundColor(micGranted ? .green : .orange)
            Text("Доступ к микрофону")
                .font(.title2.bold())
            Text("Corvin записывает голос для транскрипции. Аудио обрабатывается на устройстве.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Spacer()
            if micGranted {
                Button("Далее") { step = 2 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 40)
            } else {
                Button("Разрешить микрофон") {
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        DispatchQueue.main.async { micGranted = granted }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
            }
        }
        .padding()
    }

    private var selectedModel: WhisperModel? {
        guard let id = selectedModelId else { return modelManager.recommendedModel }
        return modelManager.models.first(where: { $0.id == id })
    }

    /// Check if there's an active download for the selected model
    private var isModelDownloading: Bool {
        guard let model = selectedModel else { return false }
        return modelManager.downloadTasks[model.id] != nil
    }

    /// Check if ANY model is being downloaded
    private var isAnyModelDownloading: Bool {
        !modelManager.downloadTasks.isEmpty
    }

    /// Get current download progress from model (updated by ModelManager)
    private var currentDownloadProgress: Double {
        selectedModel?.downloadProgress ?? 0
    }

    private var modelStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 50))
                .foregroundColor(.blue)
                .padding(.top, 24)
            Text("Загрузка модели")
                .font(.title2.bold())
            Text("Выберите модель для распознавания речи")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Text("Small — разумный компромисс между размером, скоростью и качеством распознавания нескольких языков.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Model list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(modelManager.models) { model in
                        let isSelected = (selectedModelId ?? modelManager.recommendedModel?.id) == model.id
                        let isThisModelDownloading = modelManager.downloadTasks[model.id] != nil
                        Button {
                            if !isModelDownloading {
                                selectedModelId = model.id
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .font(.headline)
                                        if model.recommended {
                                            Text("рек.")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.2))
                                                .foregroundColor(.blue)
                                                .cornerRadius(4)
                                        }
                                    }
                                    if isThisModelDownloading {
                                        Text("\(model.size) · Загрузка: \(Int(model.downloadProgress * 100))%")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    } else {
                                        Text("\(model.size) · Качество: \(model.quality)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if model.isDownloaded {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else if isThisModelDownloading {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if isSelected {
                                    Image(systemName: "circle.inset.filled")
                                        .foregroundColor(.blue)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .background(isSelected ? Color.blue.opacity(0.1) : Color(.secondarySystemBackground))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .disabled(isModelDownloading)
                    }
                }
                .padding(.horizontal)
            }

            // Download progress or download button
            if let model = selectedModel {
                if model.isDownloaded {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Модель загружена")
                    }
                } else if isModelDownloading {
                    VStack(spacing: 4) {
                        ProgressView(value: currentDownloadProgress)
                            .padding(.horizontal, 40)
                        Text("Загрузка: \(Int(currentDownloadProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button("Загрузить \(model.name)") {
                        // Start download - progress tracked by ModelManager
                        modelManager.downloadModel(model, progress: { _ in }, completion: { [weak modelManager] result in
                            if case .success = result {
                                modelManager?.setActiveModel(model)
                            }
                        })
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            // Bottom buttons
            if modelManager.activeModel != nil || isAnyModelDownloading {
                // "Готово" — model already active or downloading in background
                Button("Готово") {
                    completeOnboarding()
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                // No model yet and not downloading — allow skip
                Button("Настроить позже") {
                    completeOnboarding()
                }
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding()
        .padding(.bottom, 24)
    }

    private func completeOnboarding() {
        // Enable background mode (PiP) for seamless keyboard experience
        if PiPService.shared.isPiPPossible && !PiPService.shared.isPiPActive {
            PiPService.shared.startPiP()
        }
        // Reset step for potential future re-onboarding
        step = 0
        onComplete()
    }

}
