import Foundation
import Combine
import CryptoKit

enum ChipType: String, Codable {
    case applesilicon
    case intel
}

enum ModelTier: String, Codable {
    case free
    case pro
}

struct WhisperModel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let size: String
    let ramRequired: String
    let quality: String
    let speed: String
    let downloadURL: URL
    let sha256: String
    let recommended: Bool
    let chipRequirement: ChipType? // nil = works on both
    let tier: ModelTier
    var isDownloaded: Bool = false
    var downloadProgress: Double = 0

    var isPro: Bool { tier == .pro }

    private static let whisperURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    static let all: [WhisperModel] = [
        // --- Universal (Apple Silicon + Intel) ---
        WhisperModel(
            id: "tiny", name: "tiny", size: "75 MB", ramRequired: "~125 MB",
            quality: "models.quality.basic", speed: "~10x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-tiny.bin")!,
            sha256: "", recommended: false, chipRequirement: nil, tier: .free
        ),
        WhisperModel(
            id: "base", name: "base", size: "142 MB", ramRequired: "~210 MB",
            quality: "models.quality.normal", speed: "~7x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-base.bin")!,
            sha256: "", recommended: false, chipRequirement: nil, tier: .free
        ),
        WhisperModel(
            id: "small", name: "small", size: "466 MB", ramRequired: "~600 MB",
            quality: "models.quality.good", speed: "~4x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-small.bin")!,
            sha256: "", recommended: true, chipRequirement: nil, tier: .free
        ),

        // --- Apple Silicon recommended ---
        WhisperModel(
            id: "medium", name: "medium", size: "1.5 GB", ramRequired: "~1.7 GB",
            quality: "models.quality.excellent", speed: "~2x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-medium.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),
        WhisperModel(
            id: "large-v3", name: "large-v3", size: "3.1 GB", ramRequired: "~3.3 GB",
            quality: "models.quality.best", speed: "~1x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v3.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),
        WhisperModel(
            id: "large-v3-turbo", name: "large-v3-turbo", size: "1.6 GB", ramRequired: "~1.8 GB",
            quality: "models.quality.best", speed: "~3x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v3-turbo.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),

        // --- Quantized (big model quality in small size) ---
        WhisperModel(
            id: "large-v3-turbo-q5_0", name: "large-v3-turbo-q5_0", size: "574 MB", ramRequired: "~700 MB",
            quality: "models.quality.best_compressed", speed: "~3x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v3-turbo-q5_0.bin")!,
            sha256: "", recommended: false, chipRequirement: nil, tier: .free
        ),
        WhisperModel(
            id: "large-v3-turbo-q8_0", name: "large-v3-turbo-q8_0", size: "874 MB", ramRequired: "~1.0 GB",
            quality: "models.quality.best_compressed", speed: "~3x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v3-turbo-q8_0.bin")!,
            sha256: "", recommended: false, chipRequirement: nil, tier: .free
        ),
        WhisperModel(
            id: "large-v3-q5_0", name: "large-v3-q5_0", size: "1.08 GB", ramRequired: "~1.3 GB",
            quality: "models.quality.best_compressed", speed: "~1x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v3-q5_0.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),
        WhisperModel(
            id: "medium-q5_0", name: "medium-q5_0", size: "539 MB", ramRequired: "~650 MB",
            quality: "models.quality.excellent_compressed", speed: "~2x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-medium-q5_0.bin")!,
            sha256: "", recommended: false, chipRequirement: nil, tier: .free
        ),

        // --- English-optimized ---
        WhisperModel(
            id: "small.en", name: "small.en", size: "466 MB", ramRequired: "~600 MB",
            quality: "models.quality.english_optimized", speed: "~4x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-small.en.bin")!,
            sha256: "", recommended: false, chipRequirement: nil, tier: .free
        ),
        WhisperModel(
            id: "medium.en", name: "medium.en", size: "1.5 GB", ramRequired: "~1.7 GB",
            quality: "models.quality.english_optimized", speed: "~2x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-medium.en.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),

        // --- Distilled (speed + quality) ---
        WhisperModel(
            id: "distil-large-v3", name: "distil-large-v3", size: "756 MB", ramRequired: "~900 MB",
            quality: "models.quality.best_fast", speed: "~6x realtime",
            downloadURL: URL(string: "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),

        // --- Alternative large models ---
        WhisperModel(
            id: "large-v2", name: "large-v2", size: "3.09 GB", ramRequired: "~3.3 GB",
            quality: "models.quality.best", speed: "~1x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v2.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),
        WhisperModel(
            id: "large-v2-q5_0", name: "large-v2-q5_0", size: "1.08 GB", ramRequired: "~1.3 GB",
            quality: "models.quality.best_compressed", speed: "~1x realtime",
            downloadURL: URL(string: "\(whisperURL)/ggml-large-v2-q5_0.bin")!,
            sha256: "", recommended: false, chipRequirement: .applesilicon, tier: .free
        ),
    ]
}

class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var models: [WhisperModel] = []
    @Published var activeModel: WhisperModel?
    @Published private(set) var downloadTasks: [String: URLSessionDownloadTask] = [:]

    private let modelsDirectory: URL
    private var session: URLSession!
    let chipType: ChipType
    private var progressCallbacks: [String: (Double) -> Void] = [:]
    private var completionCallbacks: [String: (Result<Void, Error>) -> Void] = [:]
    /// Maps URLSessionTask.taskIdentifier -> modelId
    private var taskModelMap: [Int: String] = [:]

    override init() {
        #if os(iOS)
        chipType = .applesilicon
        #elseif arch(x86_64)
        chipType = .intel
        #else
        chipType = .applesilicon
        #endif

        #if os(iOS)
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.corvinvoice.app") {
            modelsDirectory = groupURL.appendingPathComponent("Models", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            modelsDirectory = appSupport.appendingPathComponent("Corvin/Models", isDirectory: true)
        }
        #else
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("Corvin/Models", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        super.init()

        // Use background session for iOS to survive app termination
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: "com.corvinvoice.ios.modeldownload")
        config.isDiscretionary = false  // Don't delay downloads
        config.sessionSendsLaunchEvents = true  // Wake app when download completes
        #else
        let config = URLSessionConfiguration.default
        #endif
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        models = WhisperModel.all.filter { model in
            model.chipRequirement == nil || model.chipRequirement == chipType
        }

        installBundledModels()
        refreshModelStatus()
        reconnectToExistingTasks()
    }

    /// Reconnect to any background download tasks that survived app restart
    private func reconnectToExistingTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            flog("reconnectToExistingTasks: found \(tasks.count) existing tasks")
            for task in tasks {
                if let downloadTask = task as? URLSessionDownloadTask,
                   let url = task.originalRequest?.url {
                    // Find model by URL
                    if let model = self.models.first(where: { $0.downloadURL == url }) {
                        flog("reconnectToExistingTasks: reconnecting to \(model.id), taskId=\(task.taskIdentifier), state=\(task.state.rawValue)")
                        self.downloadTasks[model.id] = downloadTask
                        self.taskModelMap[task.taskIdentifier] = model.id
                    }
                }
            }
        }
        // Also check for resume data from previous incomplete downloads
        resumeIncompleteDownloads()
    }

    // MARK: - Resume data persistence

    private func resumeDataPath(for modelId: String) -> URL {
        modelsDirectory.appendingPathComponent(".resume-\(modelId).dat")
    }

    private func saveResumeData(_ data: Data, for modelId: String) {
        try? data.write(to: resumeDataPath(for: modelId))
    }

    private func loadResumeData(for modelId: String) -> Data? {
        let path = resumeDataPath(for: modelId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? Data(contentsOf: path)
    }

    private func clearResumeData(for modelId: String) {
        try? FileManager.default.removeItem(at: resumeDataPath(for: modelId))
    }

    private func resumeIncompleteDownloads() {
        for model in models where !model.isDownloaded {
            if let resumeData = loadResumeData(for: model.id) {
                let task = session.downloadTask(withResumeData: resumeData)
                downloadTasks[model.id] = task
                taskModelMap[task.taskIdentifier] = model.id
                task.resume()
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        flog("Download finished for taskId=\(downloadTask.taskIdentifier)")
        guard let modelId = taskModelMap[downloadTask.taskIdentifier],
              let model = models.first(where: { $0.id == modelId }) else {
            flog("Download finished but no model found for taskId=\(downloadTask.taskIdentifier)")
            return
        }

        flog("Moving downloaded model \(modelId) to final location")
        let destination = modelPath(for: model)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            clearResumeData(for: modelId)
            refreshModelStatus()
            if activeModel == nil {
                setActiveModel(model)
            }
            flog("Model \(modelId) downloaded successfully")
            completionCallbacks[modelId]?(.success(()))
        } catch {
            flog("Failed to move model \(modelId): \(error)")
            completionCallbacks[modelId]?(.failure(error))
        }
        cleanupTask(modelId: modelId, taskId: downloadTask.taskIdentifier)
    }

    private var lastProgressLog: [String: Date] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let modelId = taskModelMap[downloadTask.taskIdentifier] else { return }
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        if let idx = models.firstIndex(where: { $0.id == modelId }) {
            models[idx].downloadProgress = p
        }
        progressCallbacks[modelId]?(p)

        // Log progress every 5 seconds
        let now = Date()
        if lastProgressLog[modelId] == nil || now.timeIntervalSince(lastProgressLog[modelId]!) > 5 {
            lastProgressLog[modelId] = now
            flog("Download progress \(modelId): \(Int(p * 100))% (\(totalBytesWritten)/\(totalBytesExpectedToWrite))")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let modelId = taskModelMap[task.taskIdentifier] else {
            flog("Task completed but no model found for taskId=\(task.taskIdentifier), error=\(error?.localizedDescription ?? "none")")
            return
        }
        if let error = error {
            flog("Download failed for \(modelId): \(error.localizedDescription)")
            // Save resume data if available
            let nsError = error as NSError
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                flog("Saved resume data for \(modelId): \(resumeData.count) bytes")
                saveResumeData(resumeData, for: modelId)
            }
            completionCallbacks[modelId]?(.failure(error))
        } else {
            flog("Task completed without error for \(modelId)")
        }
        cleanupTask(modelId: modelId, taskId: task.taskIdentifier)
    }

    private func cleanupTask(modelId: String, taskId: Int) {
        downloadTasks.removeValue(forKey: modelId)
        taskModelMap.removeValue(forKey: taskId)
        progressCallbacks.removeValue(forKey: modelId)
        completionCallbacks.removeValue(forKey: modelId)
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        flog("urlSessionDidFinishEvents called - all background events processed")
        BackgroundSessionManager.shared.callCompletionHandlerIfNeeded()
    }
    #endif

    var modelsPath: URL { modelsDirectory }

    var isIntel: Bool { chipType == .intel }


    var recommendedModel: WhisperModel? {
        if chipType == .applesilicon {
            return models.first(where: { $0.recommended })
        } else {
            // Intel: recommend small as the heaviest reasonable model
            return models.first(where: { $0.id == "small" })
        }
    }

    func modelPath(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent("ggml-\(model.name).bin")
    }

    private var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        return .standard
        #endif
    }

    /// Copy models bundled inside the app into the user's models directory (first launch only)
    private func installBundledModels() {
        #if os(macOS)
        guard let bundledModelsURL = Bundle.main.resourceURL?.appendingPathComponent("Models") else { return }
        guard FileManager.default.fileExists(atPath: bundledModelsURL.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: bundledModelsURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "bin" {
            let dest = modelsDirectory.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: file, to: dest)
            }
        }
        #endif
    }

    func refreshModelStatus() {
        for i in models.indices {
            let path = modelPath(for: models[i])
            models[i].isDownloaded = FileManager.default.fileExists(atPath: path.path)
        }

        if let savedActive = defaults.string(forKey: "activeModelId"),
           let model = models.first(where: { $0.id == savedActive && $0.isDownloaded }) {
            activeModel = model
        } else {
            activeModel = models.first(where: { $0.isDownloaded })
        }
    }

    func setActiveModel(_ model: WhisperModel) {
        guard model.isDownloaded else { return }
        activeModel = model
        defaults.set(model.id, forKey: "activeModelId")
    }

    func downloadModel(_ model: WhisperModel, progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        flog("downloadModel called for \(model.id), existing task: \(downloadTasks[model.id] != nil)")

        guard downloadTasks[model.id] == nil else {
            // Already downloading — just update callbacks
            flog("downloadModel: already downloading \(model.id), updating callbacks")
            progressCallbacks[model.id] = progress
            completionCallbacks[model.id] = completion
            return
        }

        progressCallbacks[model.id] = progress
        completionCallbacks[model.id] = completion

        let task: URLSessionDownloadTask
        if let resumeData = loadResumeData(for: model.id) {
            flog("downloadModel: resuming \(model.id) from saved data")
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            flog("downloadModel: starting fresh download for \(model.id)")
            task = session.downloadTask(with: model.downloadURL)
        }

        downloadTasks[model.id] = task
        taskModelMap[task.taskIdentifier] = model.id
        task.resume()
        flog("downloadModel: task started for \(model.id), taskId=\(task.taskIdentifier)")
    }

    func cancelDownload(_ model: WhisperModel) {
        if let task = downloadTasks[model.id] {
            task.cancel(byProducingResumeData: { [weak self] data in
                if let data = data {
                    self?.saveResumeData(data, for: model.id)
                }
            })
        }
        downloadTasks.removeValue(forKey: model.id)
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx].downloadProgress = 0
        }
    }

    func deleteModel(_ model: WhisperModel) {
        let path = modelPath(for: model)
        try? FileManager.default.removeItem(at: path)
        refreshModelStatus()
        if activeModel?.id == model.id {
            activeModel = models.first(where: { $0.isDownloaded })
        }
    }

    enum ModelError: LocalizedError {
        case downloadFailed
        case checksumMismatch
        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "Не удалось скачать модель"
            case .checksumMismatch: return "Контрольная сумма не совпадает"
            }
        }
    }
}
