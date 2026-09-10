import Foundation
import CWhisper
import os.log

private let engineLogger = Logger(subsystem: "com.corvin.engine", category: "transcription")

// TranscriptionResult is defined in Shared/Networking/TranscriptionModels.swift

/// Progress through the chunk list of a single transcription.
/// A struct rather than a tuple so it is `Equatable` and SwiftUI can diff it.
struct ChunkProgress: Equatable {
    var current: Int = 0
    var total: Int = 0

    static let none = ChunkProgress()
}

class TranscriptionEngine: ObservableObject {
    private let modelManager: ModelManager
    private var whisperContext: OpaquePointer?
    private var loadedModelId: String?
    private let whisperLock = NSLock()
    private var keepAliveTimer: DispatchSourceTimer?
    /// Interval between keep-alive pings that prevent macOS from paging model out of RAM
    private let keepAliveInterval: TimeInterval = 120 // 2 minutes

    /// Bumped every time the whisper context is freed. Replaces the old
    /// `shouldAbort` bool, which `unloadModel()` reset to `false` on its way
    /// out: a chunk loop that had been signalled to stop would find the flag
    /// clear again and call `whisper_full` on the pointer that had just been
    /// freed. A counter is never "un-signalled", so a run that started on
    /// generation N stays invalid forever once the context moves to N+1.
    private var modelGeneration: Int = 0
    private let generationLock = NSLock()

    /// Chunk progress of whatever transcription ran most recently. Shared
    /// across callers by nature — per-call progress goes through the
    /// `onProgress` closure of `transcribe(audioData:onProgress:shouldYield:)`.
    @Published var chunkProgress: ChunkProgress = .none

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
            guard let self = self else { return }
            // Tiny 0.1s silent buffer — just enough to touch model memory pages
            let samples = [Float](repeating: 0, count: 1600)
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = 1
            params.print_progress = false
            // Skip the tick rather than queue behind a real transcription —
            // the pages are hot anyway while one is running, and waiting here
            // only lines this up to clobber ctx the moment the lock is free.
            guard self.whisperLock.try() else {
                flog("keepAlive: skipped, transcription in progress")
                return
            }
            defer { self.whisperLock.unlock() }
            // Read the context under the lock, never from outside it.
            guard let ctx = self.whisperContext else { return }
            samples.withUnsafeBufferPointer { ptr in
                _ = whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
            }
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
        #if targetEnvironment(simulator)
        // The simulator's Metal device reports recommendedMaxWorkingSetSize = 0
        // and aborts on the model's buffer allocation. CPU is slow here but it
        // is the only way the app runs at all under the simulator.
        params.use_gpu = false
        flog("GPU disabled (simulator has no usable Metal device)")
        #else
        // Enable Metal GPU on iOS for faster transcription
        params.use_gpu = true
        flog("GPU enabled for iOS (Metal)")
        #endif
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

    /// - Parameters:
    ///   - onProgress: per-call chunk progress `(current, total)`, called off
    ///     the main thread. Use this instead of `chunkProgress` when more than
    ///     one transcription can be in flight (the batch queue plus the hotkey
    ///     flow) — the published property belongs to whoever ran last.
    ///   - shouldYield: polled between chunks; while it returns `true` the run
    ///     parks itself instead of taking the lock. `whisperLock` only spans a
    ///     single chunk, so without this a live dictation would queue behind a
    ///     25-second batch chunk before *each* of its own chunks.
    ///   - shouldCancel: polled between chunks and from whisper's
    ///     `abort_callback`, so a long file stops within the chunk in flight
    ///     rather than at its end. Throws `CancellationError` once it fires.
    func transcribe(audioData: Data,
                    onProgress: ((Int, Int) -> Void)? = nil,
                    shouldYield: (() -> Bool)? = nil,
                    shouldCancel: (() -> Bool)? = nil) async throws -> TranscriptionResult {
        engineLogger.info("transcribe called, audioData: \(audioData.count) bytes")

        // Minimum ~0.5s of audio at 16kHz 16-bit mono = 16000 bytes
        if audioData.count < 16000 {
            flog("audio too short: \(audioData.count) bytes, skipping whisper_full")
            return TranscriptionResult(text: "", language: "")
        }

        flog("starting transcription with \(audioData.count) bytes of audio")
        return try await withCheckedThrowingContinuation { continuation in
            var thread: Thread!
            thread = Thread {
                // Loading happens here rather than in the async prologue: it
                // takes `whisperLock`, and blocking a cooperative-pool thread
                // on a lock held for a whole 25-second chunk is exactly what
                // that pool must never do.
                let myGeneration: Int
                do {
                    myGeneration = try self.prepareContext()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

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

                DispatchQueue.main.async { self.chunkProgress = ChunkProgress(current: 0, total: chunks.count) }
                onProgress?(0, chunks.count)

                let abortToken = AbortToken(engine: self, generation: myGeneration,
                                            shouldCancel: shouldCancel)

                var fullText = ""
                var detectedLang = ""
                var cancelled = false

                for (idx, chunk) in chunks.enumerated() {
                    // Step aside for the live dictation flow rather than
                    // interleaving chunk-for-chunk with it.
                    while shouldYield?() == true, shouldCancel?() != true,
                          self.currentGeneration() == myGeneration {
                        Thread.sleep(forTimeInterval: 0.1)
                    }

                    if shouldCancel?() == true {
                        flog("transcription cancelled at chunk \(idx)")
                        cancelled = true
                        break
                    }

                    guard self.currentGeneration() == myGeneration else {
                        flog("transcription aborted at chunk \(idx): model generation changed")
                        break
                    }

                    DispatchQueue.main.async { self.chunkProgress = ChunkProgress(current: idx + 1, total: chunks.count) }
                    onProgress?(idx + 1, chunks.count)
                    flog("chunk \(idx+1)/\(chunks.count): \(chunk.count) samples (\(String(format: "%.1f", Float(chunk.count) / 16000.0))s)")

                    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    params.language = nil
                    params.translate = false
                    params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
                    params.print_progress = false

                    // The token carries the generation this run started on, so
                    // the callback aborts only for *its own* invalidation and
                    // not for some unrelated later reload.
                    params.abort_callback = { userData in
                        guard let ptr = userData else { return false }
                        let token = Unmanaged<AbortToken>.fromOpaque(ptr).takeUnretainedValue()
                        return token.engine.currentGeneration() != token.generation
                            || token.shouldCancel?() == true
                    }
                    params.abort_callback_user_data = Unmanaged.passUnretained(abortToken).toOpaque()

                    // The lock has to span the result readout, not just the run:
                    // the segment texts live inside ctx and the next whisper_full
                    // on the same ctx frees them. Reading them unlocked let the
                    // keepAlive tick overwrite the buffer mid-copy, which handed
                    // String(cString:) bytes that changed after it had validated
                    // them — an ill-formed String that later trapped in AppKit.
                    self.whisperLock.lock()

                    // Re-read the context every chunk instead of capturing it
                    // once before the loop: between two chunks the model can be
                    // swapped out from under us and the old pointer freed.
                    guard let ctx = self.whisperContext, self.currentGeneration() == myGeneration else {
                        self.whisperLock.unlock()
                        flog("transcription aborted at chunk \(idx): context released")
                        break
                    }

                    let result = withExtendedLifetime(abortToken) {
                        chunk.withUnsafeBufferPointer { ptr in
                            whisper_full(ctx, params, ptr.baseAddress, Int32(chunk.count))
                        }
                    }

                    if result != 0 {
                        self.whisperLock.unlock()
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
                    self.whisperLock.unlock()
                    flog("chunk \(idx+1) done, total text length: \(fullText.count)")
                }

                DispatchQueue.main.async { self.chunkProgress = .none }

                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Belt and braces: re-decode before publishing. A String that
                // claims to hold valid UTF-8 but doesn't will trap the moment
                // AppKit walks it as UTF-16 — better a row of ￼ than a SIGTRAP.
                let text = String(decoding: Array(fullText.utf8), as: UTF8.self)
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
        // Bump before taking the lock: an in-flight whisper_full polls the
        // generation through abort_callback, unwinds, and hands us the lock.
        bumpGeneration()
        whisperLock.lock()
        freeContextLocked()
        whisperLock.unlock()
    }

    /// Make sure the context matches the active model and return the
    /// generation this run is entitled to use.
    ///
    /// All of it under the lock: unlocked, two callers could both decide the
    /// model needed swapping and the loser would free the context the winner
    /// was already running on.
    private func prepareContext() throws -> Int {
        whisperLock.lock()
        defer { whisperLock.unlock() }

        let currentId = modelManager.activeModel?.id
        if whisperContext == nil || loadedModelId != currentId {
            engineLogger.info("need to load/reload model (ctx=\(self.whisperContext == nil ? "nil" : "set"), loaded=\(self.loadedModelId ?? "nil"), current=\(currentId ?? "nil"))")
            bumpGeneration()
            freeContextLocked()
            try loadModel()
        }
        guard whisperContext != nil else { throw TranscriptionError.noModel }
        return currentGeneration()
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return modelGeneration
    }

    /// Invalidate every transcription currently running on this context.
    private func bumpGeneration() {
        generationLock.lock()
        modelGeneration &+= 1
        generationLock.unlock()
    }

    /// Free the whisper context. Caller must hold `whisperLock` and must have
    /// bumped the generation first, or an in-flight run will keep using it.
    private func freeContextLocked() {
        guard let ctx = whisperContext else { return }
        flog("unloading model (loadedModelId=\(loadedModelId ?? "nil"))")
        whisper_free(ctx)
        whisperContext = nil
        loadedModelId = nil
    }

    /// Ties an `abort_callback` to the generation its run started on.
    /// A C function pointer cannot capture, so the pair travels as user data.
    private final class AbortToken {
        let engine: TranscriptionEngine
        let generation: Int
        let shouldCancel: (() -> Bool)?
        init(engine: TranscriptionEngine, generation: Int, shouldCancel: (() -> Bool)?) {
            self.engine = engine
            self.generation = generation
            self.shouldCancel = shouldCancel
        }
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
        // 1 second of silence at 16kHz
        let samples = [Float](repeating: 0, count: 16000)
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.print_progress = false
        whisperLock.lock()
        defer { whisperLock.unlock() }
        if whisperContext == nil {
            try? loadModel()
        }
        guard let ctx = whisperContext else { return }
        samples.withUnsafeBufferPointer { ptr in
            _ = whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }
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
            case .noModel: return "engine.noModel".localized
            case .modelLoadFailed: return "engine.modelLoadFailed".localized
            case .transcriptionFailed: return "engine.transcriptionFailed".localized
            }
        }
    }
}
