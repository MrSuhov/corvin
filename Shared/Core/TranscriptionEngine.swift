import Foundation
import CWhisper
import os.log

private let engineLogger = Logger(subsystem: "com.corvin.engine", category: "transcription")

// TranscriptionResult is defined in Shared/Networking/TranscriptionModels.swift

class TranscriptionEngine: ObservableObject {
    private let modelManager: ModelManager
    private var whisperContext: OpaquePointer?
    private var loadedModelId: String?
    private let whisperLock = NSLock()
    private var shouldAbort = false
    private var keepAliveTimer: DispatchSourceTimer?
    /// Interval between keep-alive pings that prevent macOS from paging model out of RAM
    private let keepAliveInterval: TimeInterval = 120 // 2 minutes

    /// Chunk progress: (current chunk 1-based, total chunks)
    @Published var chunkProgress: (current: Int, total: Int) = (0, 0)

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Start periodic silent inference to keep model memory pages hot in RAM.
    /// macOS pages out inactive memory to swap; this prevents that for the whisper model.
    func startKeepAlive() {
        stopKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer.schedule(deadline: .now() + keepAliveInterval, repeating: keepAliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, let ctx = self.whisperContext else { return }
            // Tiny 0.1s silent buffer — just enough to touch model memory pages
            let samples = [Float](repeating: 0, count: 1600)
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = 1
            params.print_progress = false
            self.whisperLock.lock()
            samples.withUnsafeBufferPointer { ptr in
                _ = whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
            }
            self.whisperLock.unlock()
            flog("keepAlive: model memory touched")
        }
        timer.resume()
        keepAliveTimer = timer
        flog("keepAlive: started (interval=\(Int(keepAliveInterval))s)")
    }

    func stopKeepAlive() {
        if let timer = keepAliveTimer {
            timer.cancel()
            keepAliveTimer = nil
            flog("keepAlive: stopped")
        }
    }

    func loadModel() throws {
        guard let model = modelManager.activeModel else {
            engineLogger.error("no active model")
            throw TranscriptionError.noModel
        }

        let path = modelManager.modelPath(for: model).path
        engineLogger.info("loading model: \(model.name) from: \(path)")
        engineLogger.info("file exists: \(FileManager.default.fileExists(atPath: path))")

        // whisper_init_from_file from whisper.cpp
        var params = whisper_context_default_params()
        #if os(iOS)
        // Enable Metal GPU on iOS for faster transcription
        params.use_gpu = true
        flog("GPU enabled for iOS (Metal)")
        #endif
        flog("calling whisper_init_from_file_with_params...")
        whisperContext = whisper_init_from_file_with_params(path, params)
        if whisperContext == nil {
            flog("whisper_init returned nil")
            throw TranscriptionError.modelLoadFailed
        }
        loadedModelId = model.id
        flog("model loaded successfully")
    }

    func transcribe(audioData: Data) async throws -> TranscriptionResult {
        engineLogger.info("transcribe called, audioData: \(audioData.count) bytes")
        // Reload if model changed or not loaded
        let currentId = modelManager.activeModel?.id
        if whisperContext == nil || loadedModelId != currentId {
            engineLogger.info("need to load/reload model (ctx=\(self.whisperContext == nil ? "nil" : "set"), loaded=\(self.loadedModelId ?? "nil"), current=\(currentId ?? "nil"))")
            unloadModel()
            try loadModel()
        }

        guard let ctx = whisperContext else {
            throw TranscriptionError.noModel
        }

        // Minimum ~0.5s of audio at 16kHz 16-bit mono = 16000 bytes
        if audioData.count < 16000 {
            flog("audio too short: \(audioData.count) bytes, skipping whisper_full")
            return TranscriptionResult(text: "", language: "")
        }

        flog("starting transcription with \(audioData.count) bytes of audio")
        return try await withCheckedThrowingContinuation { continuation in
            var thread: Thread!
            thread = Thread {
                // Convert Data to [Float] PCM samples
                var samples = audioData.withUnsafeBytes { buffer -> [Float] in
                    let int16Buffer = buffer.bindMemory(to: Int16.self)
                    return int16Buffer.map { Float($0) / 32768.0 }
                }

                // Log audio stats
                var maxAmp = samples.map { abs($0) }.max() ?? 0
                let avgAmp = samples.map { abs($0) }.reduce(0, +) / Float(max(samples.count, 1))
                let nonSilent = samples.filter { abs($0) > 0.01 }.count
                flog("audio stats: maxAmp=\(String(format: "%.4f", maxAmp)), avgAmp=\(String(format: "%.6f", avgAmp)), nonSilent=\(nonSilent)/\(samples.count) (\(String(format: "%.1f", Float(nonSilent) / Float(max(samples.count, 1)) * 100))%)")

                // Normalize if too quiet
                if maxAmp > 0.001 && maxAmp < 0.15 {
                    let gain = min(0.5 / maxAmp, 20.0)
                    flog("normalizing: gain=\(String(format: "%.1f", gain))x")
                    for i in samples.indices { samples[i] *= gain }
                    maxAmp = samples.map { abs($0) }.max() ?? 0
                }

                // Split into chunks (~25s each, cut at silence) for reliable processing
                let chunkSize = 25 * 16000 // 25 seconds at 16kHz
                let chunks = Self.splitAtSilence(samples: samples, maxChunkSize: chunkSize)
                flog("split into \(chunks.count) chunks (\(String(format: "%.1f", Float(samples.count) / 16000.0))s total)")

                DispatchQueue.main.async { self.chunkProgress = (0, chunks.count) }

                var fullText = ""
                var detectedLang = ""

                for (idx, chunk) in chunks.enumerated() {
                    guard !self.shouldAbort else {
                        flog("transcription aborted at chunk \(idx)")
                        break
                    }

                    DispatchQueue.main.async { self.chunkProgress = (idx + 1, chunks.count) }
                    flog("chunk \(idx+1)/\(chunks.count): \(chunk.count) samples (\(String(format: "%.1f", Float(chunk.count) / 16000.0))s)")

                    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    params.language = nil
                    params.translate = false
                    params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
                    params.print_progress = false

                    let abortPtr = Unmanaged.passUnretained(self).toOpaque()
                    params.abort_callback = { userData in
                        guard let ptr = userData else { return false }
                        let engine = Unmanaged<TranscriptionEngine>.fromOpaque(ptr).takeUnretainedValue()
                        return engine.shouldAbort
                    }
                    params.abort_callback_user_data = abortPtr

                    self.whisperLock.lock()
                    let result = chunk.withUnsafeBufferPointer { ptr in
                        whisper_full(ctx, params, ptr.baseAddress, Int32(chunk.count))
                    }
                    self.whisperLock.unlock()

                    if result != 0 {
                        flog("whisper_full failed on chunk \(idx)")
                        continue
                    }

                    let nSegments = whisper_full_n_segments(ctx)
                    for i in 0..<nSegments {
                        if let segText = whisper_full_get_segment_text(ctx, i) {
                            fullText += String(cString: segText)
                        }
                    }

                    if detectedLang.isEmpty {
                        let langId = whisper_full_lang_id(ctx)
                        detectedLang = String(cString: whisper_lang_str(langId))
                    }
                    flog("chunk \(idx+1) done, total text length: \(fullText.count)")
                }

                DispatchQueue.main.async { self.chunkProgress = (0, 0) }

                let text = fullText
                flog("all chunks done, raw text='\(text.prefix(200))', lang=\(detectedLang)")

                var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Filter out whisper hallucination tokens on silence
                let blanks: Set<String> = ["[BLANK_AUDIO]", "(BLANK_AUDIO)", "[silence]", "(silence)"]
                if blanks.contains(cleaned) {
                    flog("filtered hallucination: '\(cleaned)'")
                    cleaned = ""
                }

                continuation.resume(returning: TranscriptionResult(
                    text: cleaned,
                    language: detectedLang
                ))
            }
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    var isModelLoaded: Bool {
        return whisperContext != nil
    }

    func unloadModel() {
        stopKeepAlive()
        // Signal abort to any in-progress whisper_full, then wait for it to finish
        shouldAbort = true
        whisperLock.lock()
        if let ctx = whisperContext {
            flog("unloading model (loadedModelId=\(loadedModelId ?? "nil"))")
            whisper_free(ctx)
            whisperContext = nil
            loadedModelId = nil
        }
        whisperLock.unlock()
        shouldAbort = false
    }

    /// Ensure model is loaded, reload if needed (e.g. after memory warning)
    func ensureModelLoaded() {
        guard modelManager.activeModel != nil else { return }
        if whisperContext == nil {
            flog("ensureModelLoaded: model not in memory, reloading")
            warmup()
        }
    }

    /// Preload model + warm up Metal shaders with a tiny silent transcription
    func warmup() {
        if whisperContext == nil {
            try? loadModel()
        }
        guard let ctx = whisperContext else { return }
        // 1 second of silence at 16kHz
        let samples = [Float](repeating: 0, count: 16000)
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.print_progress = false
        whisperLock.lock()
        samples.withUnsafeBufferPointer { ptr in
            _ = whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }
        whisperLock.unlock()
    }

    /// Split audio samples into chunks at silence boundaries.
    /// Each chunk is at most maxChunkSize samples, split at the quietest point near the boundary.
    private static func splitAtSilence(samples: [Float], maxChunkSize: Int) -> [[Float]] {
        guard samples.count > maxChunkSize else {
            return [samples]
        }

        var chunks = [[Float]]()
        var offset = 0

        while offset < samples.count {
            let remaining = samples.count - offset
            if remaining <= maxChunkSize {
                chunks.append(Array(samples[offset...]))
                break
            }

            // Look for quietest spot in the last 20% of the chunk window
            let searchStart = offset + Int(Double(maxChunkSize) * 0.8)
            let searchEnd = min(offset + maxChunkSize, samples.count)
            let windowSize = 800 // ~50ms at 16kHz

            var bestPos = searchEnd
            var bestEnergy: Float = .greatestFiniteMagnitude

            var pos = searchStart
            while pos + windowSize <= searchEnd {
                var energy: Float = 0
                for j in pos..<(pos + windowSize) {
                    energy += samples[j] * samples[j]
                }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestPos = pos + windowSize / 2
                }
                pos += windowSize / 2 // step by half window
            }

            chunks.append(Array(samples[offset..<bestPos]))
            offset = bestPos
        }

        return chunks
    }

    deinit {
        stopKeepAlive()
        unloadModel()
    }

    enum TranscriptionError: LocalizedError {
        case noModel
        case modelLoadFailed
        case transcriptionFailed

        var errorDescription: String? {
            switch self {
            case .noModel: return "Модель не загружена"
            case .modelLoadFailed: return "Не удалось загрузить модель"
            case .transcriptionFailed: return "Ошибка транскрибации"
            }
        }
    }
}
