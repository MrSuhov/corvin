import AVFoundation

/// An app whose audio a call recording captures.
struct CallApp: Equatable {
    let bundleID: String
    let name: String
    var isPlayingAudio = false
}

/// One side of a call, delivered as 16 kHz mono chunks stamped with host time.
///
/// Both sides are stamped from the same host clock, which is what lets
/// `CallTimelineWriter` line them up: their sample clocks drift apart, and the
/// system-audio side may deliver nothing at all while the app is silent.
protocol CallAudioSource: AnyObject {
    /// Samples and the host time of the first one. Called on an audio thread.
    var onChunk: (([Float], UInt64) -> Void)? { get set }
    /// Recording goes on, but the user should know something. Any thread.
    var onWarning: ((LocalizedMessage) -> Void)? { get set }
    /// The source stopped by itself and will deliver nothing more. Any thread.
    var onEnded: ((LocalizedMessage) -> Void)? { get set }

    func start() async throws
    /// Idempotent, and safe after a failed `start()`.
    func stop()
}

enum CallRecordingError: LocalizedError {
    case microphoneDenied
    case appNotFound(String)
    case screenCaptureDenied
    case captureFailed(String)

    var message: LocalizedMessage {
        switch self {
        case .microphoneDenied: return LocalizedMessage("call.error.microphoneDenied")
        case .appNotFound(let name): return LocalizedMessage("call.error.appNotFound", name)
        case .screenCaptureDenied: return LocalizedMessage("call.error.screenCaptureDenied")
        case .captureFailed(let detail): return LocalizedMessage("call.error.captureFailed", detail)
        }
    }

    var errorDescription: String? { message.text }
}

/// Any float buffer to 16 kHz mono Float32, keeping resampler state across
/// calls so a stream of chunks resamples without clicks at the seams.
///
/// Mixed down by hand first: `AVAudioConverter` does not reliably mix arbitrary
/// channel counts (see `AudioCaptureService`). One instance per stream; not
/// thread-safe.
final class MonoResampler {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }

        var mono = [Float](repeating: 0, count: frames)
        if buffer.format.isInterleaved {
            let samples = data[0]
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i * channels + c] }
                mono[i] = sum / Float(channels)
            }
        } else {
            for c in 0..<channels {
                let samples = data[c]
                for i in 0..<frames { mono[i] += samples[i] }
            }
            if channels > 1 {
                for i in 0..<frames { mono[i] /= Float(channels) }
            }
        }

        let rate = buffer.format.sampleRate
        if sourceFormat?.sampleRate != rate {
            sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = sourceFormat.flatMap { AVAudioConverter(from: $0, to: target) }
        }
        guard let converter, let sourceFormat,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Double(frames) * 16000 / rate) + 64)
        else { return [] }
        input.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }

        var fed = false
        var error: NSError?
        // `.noDataNow` rather than `.endOfStream`: the converter keeps its
        // filter state for the next chunk.
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// Where one channel's chunks land on the shared timeline.
///
/// Positions come from host time; sample counts come from a device clock that
/// drifts against it. Chunks are laid end to end while they agree with the
/// clock within `tolerance`. Beyond that the gap is filled with silence, or the
/// overlap is dropped.
struct TimelineCursor {
    /// 20 ms at 16 kHz.
    static let tolerance = 320

    /// Samples emitted so far, silence included.
    private(set) var end = 0

    mutating func place(_ samples: [Float], at position: Int) -> [Float] {
        let drift = position - end
        if abs(drift) <= Self.tolerance {
            end += samples.count
            return samples
        }
        if drift > 0 {
            end += drift + samples.count
            return [Float](repeating: 0, count: drift) + samples
        }
        let overlap = min(-drift, samples.count)
        end += samples.count - overlap
        return Array(samples.dropFirst(overlap))
    }

    /// Silence up to `position`, for a channel that went quiet while the other
    /// kept going.
    mutating func pad(to position: Int) -> [Float] {
        guard position > end else { return [] }
        let count = position - end
        end = position
        return [Float](repeating: 0, count: count)
    }
}

/// Writes a call as one 16 kHz file: left channel the microphone, right the app.
///
/// 16-bit PCM in CAF rather than AAC. Core Audio leaves a CAF data chunk
/// open-ended while writing, so a PCM recording stays readable if Corvin dies
/// mid-call; compressed audio needs a packet table that is written only on
/// close. `CallRecorder` converts to AAC once the call ends.
final class CallTimelineWriter: @unchecked Sendable {
    enum Channel: Int {
        case me = 0
        case other = 1
    }

    static let sampleRate = 16000.0
    /// A channel this far behind the other gets silence so the file keeps pace:
    /// ScreenCaptureKit sends nothing while the app is silent.
    static let maxLag = 8000
    private static let block = 1600

    private let queue = DispatchQueue(label: "com.corvin.call.writer", qos: .userInitiated)
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    // Confined to `queue`.
    private var file: AVAudioFile?
    private var origin: UInt64?
    private var cursors = [TimelineCursor(), TimelineCursor()]
    private var pending: [[Float]] = [[], []]
    private var framesWritten = 0
    private let failed = AtomicFlag()

    private let levelLock = NSLock()
    private var levelValues: [Float] = [0, 0]

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url,
                               settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                          AVSampleRateKey: Self.sampleRate,
                                          AVNumberOfChannelsKey: 2,
                                          AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false],
                               commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    }

    /// The file stopped taking writes — a full or disconnected disk. Whatever
    /// was written before stays usable.
    var hasFailed: Bool { failed.value }

    /// RMS of the latest chunk on each channel, for the indicator.
    var levels: (me: Float, other: Float) {
        levelLock.lock()
        defer { levelLock.unlock() }
        return (levelValues[0], levelValues[1])
    }

    func append(_ samples: [Float], hostTime: UInt64, channel: Channel) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        levelLock.lock()
        levelValues[channel.rawValue] = (sum / Float(samples.count)).squareRoot()
        levelLock.unlock()

        queue.async { self.place(samples, hostTime: hostTime, channel: channel.rawValue) }
    }

    /// Flush, pad the shorter channel and close the file. Returns its length in
    /// seconds. Call once, after both sources have stopped.
    func finish() -> TimeInterval {
        queue.sync {
            let longest = max(cursors[0].end, cursors[1].end)
            for c in 0..<2 { pending[c] += cursors[c].pad(to: longest) }
            write(frames: min(pending[0].count, pending[1].count))
            file = nil
            return Double(framesWritten) / Self.sampleRate
        }
    }

    private func place(_ samples: [Float], hostTime: UInt64, channel: Int) {
        guard file != nil else { return }
        let origin = self.origin ?? hostTime
        self.origin = origin
        let seconds = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: origin)
        pending[channel] += cursors[channel].place(samples, at: Int((seconds * Self.sampleRate).rounded()))

        let lead = max(cursors[0].end, cursors[1].end) - Self.maxLag
        for c in 0..<2 { pending[c] += cursors[c].pad(to: lead) }
        write(frames: min(pending[0].count, pending[1].count))
    }

    private func write(frames: Int) {
        guard let file, frames > 0 else { return }
        var offset = 0
        while offset < frames {
            let count = min(Self.block, frames - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            for c in 0..<2 {
                pending[c].withUnsafeBufferPointer { source in
                    buffer.floatChannelData![c].update(from: source.baseAddress! + offset, count: count)
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                if !failed.value {
                    failed.value = true
                    flog("CallTimelineWriter: write failed: \(error)")
                }
                break
            }
            offset += count
        }
        for c in 0..<2 { pending[c].removeFirst(offset) }
        // Nothing is going to accept these samples; holding them would grow by
        // 128 KB/s for the rest of the call.
        if failed.value { pending = [[], []] }
        framesWritten += offset
    }
}
