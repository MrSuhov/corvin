import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject var appState: iOSAppState

    /// Tab order is load-bearing: the screenshot test selects tabs by position,
    /// because the labels are localized and the identifiers below do not always
    /// survive SwiftUI's translation of a `tabItem` into a tab bar button.
    var body: some View {
        TabView {
            StatusView()
                .environmentObject(appState)
                .tabItem {
                    Image(systemName: "mic.fill")
                        .accessibilityIdentifier("tab.record")
                    Text("tab.record".localized)
                }

            iOSModelManagerView()
                .environmentObject(modelManager)
                .tabItem {
                    Image(systemName: "cpu")
                        .accessibilityIdentifier("tab.models")
                    Text("tab.models".localized)
                }
                // Quiet nudge that the remote catalogue grew; cleared as soon as
                // the list is opened.
                .badge(modelManager.unseenModelIDs.isEmpty ? 0 : modelManager.unseenModelIDs.count)

            iOSSettingsView()
                .tabItem {
                    Image(systemName: "gear")
                        .accessibilityIdentifier("tab.settings")
                    Text("tab.settings".localized)
                }

            iOSHistoryView()
                .environmentObject(historyStore)
                .tabItem {
                    Image(systemName: "clock")
                        .accessibilityIdentifier("tab.history")
                    Text("tab.history".localized)
                }
        }
        // Only ever on screen on the keyboard's wake path.
        .overlay {
            if let progress = appState.wakeProgress {
                WakeProgressView(progress: progress) {
                    appState.wakeProgress = nil
                }
            }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var appState: iOSAppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var modelManager: ModelManager
    @ObservedObject private var pipService = PiPService.shared
    @ObservedObject private var keepAlive = BackgroundKeepAliveService.shared
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
                        title: "status.ipcServer".localized,
                        value: (appState.ipcServerRunning ? "status.running" : "status.stopped").localized,
                        isOK: appState.ipcServerRunning
                    )
                    StatusRow(
                        title: "status.keyboard".localized,
                        value: "status.keyboard.checkSettings".localized,
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
                        Text("keyboardSetup.title".localized)
                            .fontWeight(.medium)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        instructionRow(number: 1, text: "keyboardSetup.step1".localized)
                        instructionRow(number: 2, text: "keyboardSetup.step2".localized)
                        instructionRow(number: 3, text: "keyboardSetup.step3".localized)
                        instructionRow(number: 4, text: "keyboardSetup.step4".localized)
                    }

                    Button("keyboardSetup.openSettings".localized) {
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

                // Background mode. The wording follows the build: with the PiP
                // layer compiled out there is no "картинка в картинке" to
                // explain, and saying otherwise would describe a window the user
                // will never see.
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $keepAlive.isEnabled) {
                        HStack {
                            #if PIP_KEEPALIVE
                            Image(systemName: "pip.fill")
                                .foregroundColor(.blue)
                            #else
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(.blue)
                            #endif
                            Text("background.title".localized)
                                .fontWeight(.medium)
                        }
                    }

                    if keepAlive.isEnabled {
                        HStack(spacing: 6) {
                            Image(systemName: keepAlive.isHoldingProcess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(keepAlive.isHoldingProcess ? .green : .orange)
                            Text(keepAlive.isHoldingProcess ? holdingDescription : "background.recovering".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = keepAlive.errorMessage ?? pipService.errorMessage {
                        Text(error.text)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    #if PIP_KEEPALIVE
                    if !pipService.isPiPPossible {
                        Text("background.pipUnavailable".localized)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("background.explanation.pip".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #else
                    Text("background.explanation".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // PTT test button
                VStack(spacing: 8) {
                    Text("record.test.title".localized)
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
                    Text("file.transcribe.title".localized)
                        .font(.headline)

                    Text("OGG (Telegram), WAV, M4A, MP3, AIFF")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("file.transcribe.pick".localized, systemImage: "doc.badge.plus")
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
                    allowedContentTypes: [.audio] + [UTType(filenameExtension: "ogg"), UTType(filenameExtension: "opus"),
                                                       UTType(filenameExtension: "webm"), UTType(filenameExtension: "weba")].compactMap { $0 },
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
            // Without this iPad renders the two-column split style, squeezing the
            // whole UI into a sidebar beside an empty detail pane.
            .navigationViewStyle(.stack)
    }

    private var holdingDescription: String {
        #if PIP_KEEPALIVE
        return (pipService.isPiPActive ? "background.active.audioAndPiP" : "background.active.audio").localized
        #else
        return "background.active".localized
        #endif
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        if let activeModel = modelManager.activeModel {
            // Model is loaded and ready
            StatusRow(title: "status.model".localized, value: activeModel.name, isOK: true)
        } else if let downloadingModel = modelManager.models.first(where: { modelManager.downloadTasks[$0.id] != nil }) {
            // Model is being downloaded
            let progress = downloadingModel.downloadProgress
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                Text("status.model".localized)
                    .fontWeight(.medium)
                Spacer()
                Text("\(downloadingModel.name) — \(Int(progress * 100))%")
                    .foregroundColor(.secondary)
            }
        } else {
            // No model loaded, no download in progress
            StatusRow(title: "status.model".localized, value: "status.model.notLoaded".localized, isOK: false)
        }
    }

    @ViewBuilder
    private var stateText: some View {
        switch sessionManager.state {
        case .idle:
            Text("record.hint".localized)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        case .recording:
            Text("record.recording".localized)
                .foregroundColor(.red)
        case .transcribing:
            ProgressView("record.transcribing".localized)
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
        .navigationTitle("logs.title".localized)
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
