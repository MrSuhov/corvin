import Foundation
import AVFoundation
import os.log

/// Records audio using AVAudioEngine.
/// Engine is started on startCapture() and stopped on stopCapture()
/// so the microphone is only active during recording.
///
/// Test mode: Set `testAudioURL` to use a pre-recorded PCM file instead of microphone.
class AudioCaptureService {
    private var audioEngine: AVAudioEngine?
    private var audioData = Data()
    private let audioDataLock = NSLock()
    private let sampleRate: Double = 16000
    private var isCapturing = false

    /// Set this URL to a 16kHz mono Int16 PCM file to use test audio instead of microphone.
    /// Used for automated testing in simulator.
    var testAudioURL: URL?

    var hasMicrophonePermission: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// No-op kept for API compatibility. Engine is started on-demand in startCapture().
    func prepareEngine() {
        flog("prepareEngine: ready (mic not active), testMode=\(testAudioURL != nil)")
    }

    /// Error returned when audio capture fails
    enum CaptureError: Error, LocalizedError {
        case sessionActivationFailed(String)
        case engineStartFailed(String)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .sessionActivationFailed(let msg):
                return "Ошибка аудио-сессии: \(msg)"
            case .engineStartFailed(let msg):
                return "Откройте приложение Corvin для записи"
            case .invalidFormat:
                return "Неверный формат аудио"
            }
        }
    }

    /// Starts audio capture. Returns nil on success, or error on failure.
    func startCapture() -> CaptureError? {
        audioDataLock.lock()
        audioData = Data()
        audioDataLock.unlock()

        // Test mode: load audio from file instead of microphone
        if let testURL = testAudioURL {
            flog("startCapture: TEST MODE - loading from \(testURL.lastPathComponent)")
            isCapturing = true
            return nil
        }

        // Ensure audio session is active (PiPService already configured it in unified mode)
        // Don't change category - unified .playAndRecord/.voiceChat mode supports both PiP and mic
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true, options: [])
            flog("startCapture: session active (category: \(session.category.rawValue), mode: \(session.mode.rawValue))")
        } catch {
            flog("startCapture: session error: \(error.localizedDescription)")
            return .sessionActivationFailed(error.localizedDescription)
        }

        // Create and start engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let native = inputNode.outputFormat(forBus: 0)
        flog("startCapture: native=\(native.sampleRate)Hz/\(native.channelCount)ch")

        guard native.sampleRate > 0 else {
            flog("startCapture: invalid native format")
            return .invalidFormat
        }

        let targetRate = sampleRate
        let step = native.sampleRate / targetRate // e.g. 48000/16000 = 3

        isCapturing = true
        var tapCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self = self, self.isCapturing else { return }

            tapCount += 1
            let frames = Int(buffer.frameLength)

            guard let floatData = buffer.floatChannelData, frames > 0 else {
                if tapCount <= 3 { flog("tap #\(tapCount): no float data, frames=\(frames)") }
                return
            }

            // Manual downsample: pick every `step`-th sample, convert float → Int16
            let channel0 = floatData[0]
            let outFrames = Int(Double(frames) / step)
            var int16Samples = [Int16](repeating: 0, count: outFrames)
            for i in 0..<outFrames {
                let srcIdx = Int(Double(i) * step)
                let sample = max(-1.0, min(1.0, channel0[srcIdx]))
                int16Samples[i] = Int16(sample * 32767.0)
            }

            let byteData = int16Samples.withUnsafeBytes { Data($0) }

            self.audioDataLock.lock()
            self.audioData.append(byteData)
            let total = self.audioData.count
            self.audioDataLock.unlock()

            if tapCount <= 5 {
                flog("tap #\(tapCount): frames=\(frames) → \(outFrames) samples, +\(byteData.count)b total=\(total)")
            }
        }

        do {
            try engine.start()
            flog("startCapture: engine started")
        } catch {
            flog("startCapture: engine start error: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            isCapturing = false
            return .engineStartFailed(error.localizedDescription)
        }

        self.audioEngine = engine
        return nil
    }

    func stopCapture() -> Data {
        isCapturing = false

        // Test mode: return audio from file
        if let testURL = testAudioURL {
            flog("stopCapture: TEST MODE - reading from \(testURL.lastPathComponent)")
            do {
                let data = try Data(contentsOf: testURL)
                flog("stopCapture: TEST MODE - loaded \(data.count) bytes")
                return data
            } catch {
                flog("stopCapture: TEST MODE - failed to load: \(error.localizedDescription)")
                return Data()
            }
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            flog("stopCapture: engine stopped")
        }
        audioEngine = nil

        // Don't change audio session category - unified mode supports both PiP and recording
        // Just keep session active for PiP
        flog("stopCapture: keeping unified audio session active for PiP")

        audioDataLock.lock()
        let captured = audioData
        audioData = Data()
        audioDataLock.unlock()

        flog("stopCapture: \(captured.count) bytes")
        return captured
    }
}
