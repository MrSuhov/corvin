import Foundation

/// Whisper as a live transcriber: re-transcribes the recent audio about once a
/// second and commits the words that two consecutive runs agree on.
///
/// Whisper has no streaming mode — every run sees a whole window. The buffer
/// grows as the user speaks and is cut back once its start is settled, so a
/// window stays well inside whisper's 30-second context.
///
/// Everything except `append` runs on one serial queue, so runs never overlap
/// and the hypothesis needs no lock. Only the audio buffer is shared with the
/// capture thread, guarded by `lock`.
final class WhisperStreamingRecognizer: SpeechRecognizer {
    let events: AsyncStream<TranscriptEvent>
    let displayName: String

    private static let sampleRate = 16_000.0
    /// How often a run is attempted.
    private static let step: TimeInterval = 1.0
    /// A run needs at least this much audio the previous run did not hear.
    private static let minNewAudio: TimeInterval = 0.5
    private static let minWindow: TimeInterval = 1.0
    /// Past this length the buffer is cut back to the end of the last fully
    /// committed segment.
    private static let trimAfter: TimeInterval = 15
    /// Past this length, words are committed without a second opinion so the
    /// window cannot outgrow whisper's 30-second context.
    private static let forceCommitAfter: TimeInterval = 25
    private static let noSpeechThreshold: Float = 0.6
    private static let blankWords: Set<String> = ["[BLANK_AUDIO]", "(BLANK_AUDIO)", "[silence]", "(silence)"]

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let engine: TranscriptionEngine
    private let queue = DispatchQueue(label: "com.corvin.whisperStreaming", qos: .userInitiated)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var audio: [Float] = []
    private var bufferStartSample = 0
    private var receivedSamples = 0
    private var cancelled = false

    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var hypothesis = HypothesisBuffer()
    private var samplesAtLastRun = 0
    private var gain: Float?
    private var language: String?
    private var failure: Error?

    init(engine: TranscriptionEngine, displayName: String) {
        self.engine = engine
        self.displayName = displayName
        var continuation: AsyncStream<TranscriptEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start() async throws {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.step, repeating: Self.step)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func append(_ samples: [Float]) {
        lock.lock()
        audio.append(contentsOf: samples)
        receivedSamples += samples.count
        lock.unlock()
    }

    func finish() async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<TranscriptionResult, Error>) in
            queue.async { self.finishOnQueue(result) }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
        continuation.finish()
    }

    // MARK: - Queue

    private func tick() {
        guard failure == nil else { return }
        let snap = snapshot()
        guard !snap.cancelled,
              snap.received - samplesAtLastRun >= Int(Self.minNewAudio * Self.sampleRate),
              snap.window.count >= Int(Self.minWindow * Self.sampleRate) else { return }
        samplesAtLastRun = snap.received
        run(snap.window, startSample: snap.startSample, isFinal: false)
    }

    private func finishOnQueue(_ result: CheckedContinuation<TranscriptionResult, Error>) {
        timer?.cancel()
        timer = nil
        defer { continuation.finish() }

        let snap = snapshot()
        if snap.cancelled {
            result.resume(throwing: CancellationError())
            return
        }

        if failure == nil {
            if snap.window.count >= Int(0.3 * Self.sampleRate) {
                run(snap.window, startSample: snap.startSample, isFinal: true)
            } else {
                emit(hypothesis.flush())
            }
        }
        if let failure {
            result.resume(throwing: failure)
            return
        }

        let text = hypothesis.committed.map(\.text).joined(separator: " ")
        result.resume(returning: TranscriptionResult(text: text, language: language ?? ""))
    }

    private func run(_ window: [Float], startSample: Int, isFinal: Bool) {
        let windowStart = Double(startSample) / Self.sampleRate
        let duration = Double(window.count) / Self.sampleRate
        let began = CFAbsoluteTimeGetCurrent()

        let result: WhisperWindowResult
        do {
            result = try engine.transcribeWindow(samples: applyGain(window),
                                                 prompt: prompt(before: windowStart),
                                                 language: language)
        } catch {
            flog("whisperStreaming: run failed: \(error)")
            failure = error
            timer?.cancel()
            timer = nil
            return
        }

        // Auto-detect on a short window flips between languages on mixed
        // speech, so the first confident answer holds for the session.
        if language == nil, duration >= 2, !result.language.isEmpty {
            language = result.language
            flog("whisperStreaming: language fixed to \(result.language)")
        }

        let segments = result.segments.filter { $0.noSpeechProbability < Self.noSpeechThreshold }
        let words = segments.flatMap(\.words)
            .filter { !Self.blankWords.contains($0.text) }
            .map { TimedWord(text: $0.text, start: $0.start + windowStart, end: $0.end + windowStart) }

        var committed = hypothesis.insert(words)
        if isFinal {
            committed += hypothesis.flush()
        } else if duration > Self.forceCommitAfter, segments.count > 1 {
            committed += hypothesis.commit(through: windowStart + segments[segments.count - 2].end)
        }

        flog("whisperStreaming: \(isFinal ? "final " : "")window \(String(format: "%.1f", duration))s at \(String(format: "%.1f", windowStart))s took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - began))s, committed \(committed.count) words")
        emit(committed)

        if !isFinal, duration > Self.trimAfter {
            let settled = hypothesis.committedEnd
            if let cut = segments.map({ windowStart + $0.end }).last(where: { $0 <= settled + 0.05 }) {
                dropAudio(before: cut)
                flog("whisperStreaming: buffer now starts at \(String(format: "%.1f", cut))s")
            }
        }
    }

    private func emit(_ words: [TimedWord]) {
        guard !words.isEmpty else { return }
        continuation.yield(.committed(TranscriptChunk(text: words.map(\.text).joined(separator: " "))))
    }

    /// Committed text whose audio has already left the buffer. Words still in
    /// the window will be heard again, and priming the decoder with them makes
    /// it skip or repeat them.
    private func prompt(before bufferStart: TimeInterval) -> String? {
        let text = hypothesis.committed
            .filter { $0.end <= bufferStart }
            .map(\.text)
            .joined(separator: " ")
        return text.isEmpty ? nil : String(text.suffix(200))
    }

    /// Quiet mics get the same boost as in batch transcription, but the gain is
    /// fixed on the first run: re-deriving it per window would change the input
    /// under words that are still waiting for agreement.
    private func applyGain(_ window: [Float]) -> [Float] {
        if gain == nil {
            let peak = window.reduce(Float(0)) { max($0, abs($1)) }
            gain = (peak > 0.001 && peak < 0.15) ? min(0.5 / peak, 20) : 1
            flog("whisperStreaming: gain fixed at \(String(format: "%.1f", gain ?? 1))x")
        }
        guard let gain, gain != 1 else { return window }
        return window.map { $0 * gain }
    }

    // MARK: - Shared buffer

    private func snapshot() -> (window: [Float], startSample: Int, received: Int, cancelled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (audio, bufferStartSample, receivedSamples, cancelled)
    }

    private func dropAudio(before time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let target = Int(time * Self.sampleRate)
        let count = min(max(0, target - bufferStartSample), audio.count)
        audio.removeFirst(count)
        bufferStartSample += count
    }
}
