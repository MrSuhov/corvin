import Foundation
import AVFoundation

class AudioCaptureService {
    private var audioEngine: AVAudioEngine?
    private var audioData = Data()
    private let audioDataQueue = DispatchQueue(label: "com.corvin.audioCapture.data")
    private let sampleRate: Double = 16000

    /// Called on the main queue with a normalized RMS level (~0…1) while capturing.
    /// Set by callers that want live mic metering (e.g. onboarding test step). nil = no metering.
    var onLevel: ((Float) -> Void)?

    var hasMicrophonePermission: Bool {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } else {
            // Pre-14 macOS: check by attempting to access audio
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func startCapture() {
        let startTime = CFAbsoluteTimeGetCurrent()
        flog("startCapture: begin")
        audioDataQueue.sync { audioData = Data() }
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            flog("startCapture: FAILED to create AVAudioEngine")
            return
        }

        let inputNode = engine.inputNode
        flog("startCapture: inputNode accessed in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime))s")
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            flog("startCapture: FAILED to create recording format (16kHz Int16)")
            return
        }

        // Install tap to capture audio data
        let busIndex: AVAudioNodeBus = 0
        let nativeFormat = inputNode.outputFormat(forBus: busIndex)
        flog("startCapture: nativeFormat=\(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch, interleaved=\(nativeFormat.isInterleaved), common=\(nativeFormat.commonFormat.rawValue)")

        // Intermediate format: mono Float32 at native sample rate.
        // We manually downmix multi-channel → mono ourselves because AVAudioConverter
        // doesn't reliably mix arbitrary channel counts (e.g. 3ch from AirPods or
        // Continuity-Camera mics) — it often just drops channels and emits silence.
        guard let monoNativeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: monoNativeFormat, to: recordingFormat) else {
            flog("startCapture: FAILED to create monoNativeFormat or converter")
            return
        }

        var tapBufferCount = 0
        inputNode.installTap(onBus: busIndex, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Manual mono downmix (sum of channels / N) into a fresh Float32 mono buffer.
            guard let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoNativeFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                if tapBufferCount == 0 { flog("startCapture: FAILED to allocate mono buffer") }
                return
            }
            monoBuffer.frameLength = AVAudioFrameCount(frameCount)
            guard let monoOut = monoBuffer.floatChannelData?[0] else {
                if tapBufferCount == 0 { flog("startCapture: monoBuffer has no floatChannelData") }
                return
            }
            guard AudioCaptureService.downmixToMono(buffer, into: monoOut, frameCount: frameCount) else {
                if tapBufferCount == 0 { flog("startCapture: unsupported buffer format (no float/int16 channels)") }
                return
            }

            if tapBufferCount == 0 {
                var peak: Float = 0
                for i in 0..<frameCount { peak = max(peak, abs(monoOut[i])) }
                flog("startCapture: first tap buffer, frames=\(frameCount), stride=\(buffer.stride), monoPeak=\(String(format: "%.4f", peak))")
            }

            // Live metering: RMS of the clean mono signal, delivered on the main queue.
            if let cb = self.onLevel {
                var sumSq: Float = 0
                for i in 0..<frameCount { sumSq += monoOut[i] * monoOut[i] }
                let rms = frameCount > 0 ? (sumSq / Float(frameCount)).squareRoot() : 0
                DispatchQueue.main.async { cb(rms) }
            }

            // Now resample mono Float32 → mono Int16 16kHz via AVAudioConverter (sample-rate only).
            let outCapacity = AVAudioFrameCount(Double(frameCount) * self.sampleRate / nativeFormat.sampleRate + 16)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: outCapacity) else {
                if tapBufferCount == 0 { flog("startCapture: FAILED to allocate converted buffer") }
                return
            }

            var error: NSError?
            var providedOnce = false
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if providedOnce {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedOnce = true
                outStatus.pointee = .haveData
                return monoBuffer
            }

            if let error = error, tapBufferCount == 0 {
                flog("startCapture: converter error: \(error)")
            }

            if (status == .haveData || status == .inputRanDry), let channelData = convertedBuffer.int16ChannelData {
                let data = Data(bytes: channelData[0], count: Int(convertedBuffer.frameLength) * 2)
                self.audioDataQueue.sync {
                    self.audioData.append(data)
                }
            } else if tapBufferCount == 0 {
                flog("startCapture: converter status=\(status.rawValue), no data")
            }
            tapBufferCount += 1
        }

        do {
            try engine.start()
            flog("startCapture: engine started OK")
        } catch {
            flog("startCapture: engine.start() FAILED: \(error)")
        }
    }

    /// Averages every channel of `buffer` into `monoOut`, returning false when the
    /// buffer holds neither Float32 nor Int16 samples.
    ///
    /// The channel layout matters and is easy to get wrong. For a *non*-interleaved
    /// buffer, `floatChannelData` points at one array per channel. For an
    /// **interleaved** one it points at a single array, and frames sit side by
    /// side: L R L R … reached with `buffer.stride`.
    ///
    /// Indexing `floatChannelData[1]` on an interleaved buffer therefore reads
    /// past the end of a one-element pointer array — undefined behaviour that
    /// yields a different garbage signal on every run rather than a clean crash.
    /// It only bites on multi-channel input, which is why a 1-channel mic worked
    /// and a 2-channel one produced audio whose amplitude jumped between fully
    /// saturated and near-silent, transcribing to nothing either way.
    static func downmixToMono(
        _ buffer: AVAudioPCMBuffer,
        into monoOut: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride

        if let floats = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let ptr = floats[0]
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount { sum += ptr[i * stride + ch] }
                    monoOut[i] = sum
                }
            } else {
                for i in 0..<frameCount { monoOut[i] = 0 }
                for ch in 0..<channelCount {
                    let ptr = floats[ch]
                    for i in 0..<frameCount { monoOut[i] += ptr[i] }
                }
            }
        } else if let ints = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                let ptr = ints[0]
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount { sum += Float(ptr[i * stride + ch]) / 32768.0 }
                    monoOut[i] = sum
                }
            } else {
                for i in 0..<frameCount { monoOut[i] = 0 }
                for ch in 0..<channelCount {
                    let ptr = ints[ch]
                    for i in 0..<frameCount { monoOut[i] += Float(ptr[i]) / 32768.0 }
                }
            }
        } else {
            return false
        }

        if channelCount > 1 {
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frameCount { monoOut[i] *= scale }
        }
        return true
    }

    func stopCapture() -> Data {
        onLevel = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // Serialize through audioDataQueue so any in-flight tap appends complete first.
        let captured: Data = audioDataQueue.sync {
            let snapshot = audioData
            audioData = Data()
            return snapshot
        }
        flog("stopCapture: captured \(captured.count) bytes")
        return captured
    }
}
