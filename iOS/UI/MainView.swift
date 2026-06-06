import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject var appState: iOSAppState

    var body: some View {
        TabView {
            StatusView()
                .environmentObject(appState)
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("Запись")
                }

            iOSModelManagerView()
                .environmentObject(modelManager)
                .tabItem {
                    Image(systemName: "cpu")
                    Text("Модели")
                }

            iOSSettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Настройки")
                }

            iOSHistoryView()
                .environmentObject(historyStore)
                .tabItem {
                    Image(systemName: "clock")
                    Text("История")
                }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var appState: iOSAppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @ObservedObject private var pipService = PiPService.shared
    @State private var showingFilePicker = false
    @State private var importedFileName: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Status indicators
                    VStack(spacing: 12) {
                    modelStatusRow
                    StatusRow(
                        title: "IPC сервер",
                        value: appState.ipcServerRunning ? "работает" : "остановлен",
                        isOK: appState.ipcServerRunning
                    )
                    StatusRow(
                        title: "Клавиатура",
                        value: "Проверьте в Настройках iOS",
                        isOK: true
                    )
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // Keyboard setup instructions
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "keyboard")
                            .foregroundColor(.blue)
                        Text("Установка клавиатуры")
                            .fontWeight(.medium)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        instructionRow(number: 1, text: "Откройте Настройки → Основные → Клавиатура → Клавиатуры")
                        instructionRow(number: 2, text: "Нажмите «Новые клавиатуры»")
                        instructionRow(number: 3, text: "Выберите «Corvin Keyboard»")
                        instructionRow(number: 4, text: "Включите «Полный доступ»")
                    }

                    Button("Открыть Настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // PiP mode for background recording
                VStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { pipService.isPiPActive },
                        set: { newValue in
                            if newValue {
                                pipService.startPiP()
                            } else {
                                pipService.stopPiP()
                            }
                        }
                    )) {
                        HStack {
                            Image(systemName: "pip.fill")
                                .foregroundColor(.blue)
                            Text("Работа в фоне")
                                .fontWeight(.medium)
                        }
                    }

                    if !pipService.isPiPPossible {
                        Text("PiP не поддерживается на этом устройстве")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("На текущий момент единственный способ, которым Apple разрешает доступ к микрофону для фоновых приложений — это картинка в картинке.\n\nВключите перед переходом в стороннее приложение — это позволит приложению Corvin распознавать речь в фоне.\n\nПри этом микрофон телефона не включён постоянно — он активируется только в момент нажатия на кнопку микрофона.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // PTT test button
                VStack(spacing: 8) {
                    Text("Тест записи")
                        .font(.headline)

                    PTTButton(
                        isRecording: sessionManager.state == .recording,
                        onPress: { appState.startRecording() },
                        onRelease: { appState.stopRecordingAndTranscribe() }
                    )

                    stateText
                }
                .padding(.bottom, 20)

                Divider()

                VStack(spacing: 12) {
                    Text("Транскрипция файла")
                        .font(.headline)

                    Text("OGG (Telegram), WAV, M4A, MP3, AIFF")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Выбрать файл", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    if let fileName = importedFileName {
                        Text(fileName)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .fileImporter(
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [.audio] + [UTType(filenameExtension: "ogg"), UTType(filenameExtension: "opus")].compactMap { $0 },
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        importedFileName = url.lastPathComponent
                        appState.transcribeFile(url: url)
                    case .failure(let error):
                        flog("File import error: \(error)")
                    }
                }
                .padding(.bottom, 20)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Corvin")
        }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        if let activeModel = modelManager.activeModel {
            // Model is loaded and ready
            StatusRow(title: "Модель", value: activeModel.name, isOK: true)
        } else if let downloadingModel = modelManager.models.first(where: { modelManager.downloadTasks[$0.id] != nil }) {
            // Model is being downloaded
            let progress = downloadingModel.downloadProgress
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                Text("Модель")
                    .fontWeight(.medium)
                Spacer()
                Text("\(downloadingModel.name) — \(Int(progress * 100))%")
                    .foregroundColor(.secondary)
            }
        } else {
            // No model loaded, no download in progress
            StatusRow(title: "Модель", value: "не загружена", isOK: false)
        }
    }

    @ViewBuilder
    private var stateText: some View {
        switch sessionManager.state {
        case .idle:
            Text("Удерживайте кнопку для записи. Распознанный текст будет скопирован в буфер обмена.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        case .recording:
            Text("Запись...")
                .foregroundColor(.red)
        case .transcribing:
            ProgressView("Транскрипция...")
        case .done(let text):
            Text(text)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        case .error(let message):
            Text(message)
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    let isOK: Bool

    var body: some View {
        HStack {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(isOK ? .green : .orange)
            Text(title)
                .fontWeight(.medium)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

struct PTTButton: View {
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    var body: some View {
        Circle()
            .fill(isRecording ? Color.red : Color.blue)
            .frame(width: 100, height: 100)
            .overlay(
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            )
            .shadow(color: isRecording ? .red.opacity(0.4) : .blue.opacity(0.3), radius: 10)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecording { onPress() }
                    }
                    .onEnded { _ in
                        if isRecording { onRelease() }
                    }
            )
    }
}

struct LogView: View {
    @State private var logText = ""
    @State private var shareItem: ShareItem?
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            Text(logText)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Логи (последние 200)")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    FileLogger.shared.clear()
                    logText = ""
                } label: {
                    Image(systemName: "trash")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    // Export full log for sharing
                    let fullLog = FileLogger.shared.readAll()
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corvin-log.txt")
                    try? fullLog.write(to: tmp, atomically: true, encoding: .utf8)
                    shareItem = ShareItem(url: tmp)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
                .ignoresSafeArea()
        }
        .onAppear { logText = FileLogger.shared.readTail(lines: 200) }
        .onReceive(timer) { _ in logText = FileLogger.shared.readTail(lines: 200) }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
