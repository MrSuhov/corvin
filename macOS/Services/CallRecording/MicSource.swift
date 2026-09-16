import AVFoundation

/// The user's side of a call: the default microphone, with voice processing.
///
/// Voice processing cancels what the speakers play, so without headphones the
/// other side mostly stays out of this channel; `EchoFilter` handles what gets
/// through. Its own `AVAudioEngine`, so hotkey dictation keeps working during a
/// call. Where voice processing cannot start, the raw microphone is recorded.
@available(macOS 13.0, *)
final class MicSource: CallAudioSource {
    var onChunk: (([Float], UInt64) -> Void)?
    var onWarning: ((LocalizedMessage) -> Void)?
    var onEnded: ((LocalizedMessage) -> Void)?

    private var engine: AVAudioEngine?
    private var resampler = MonoResampler()
    private var voiceProcessing = true
    private var configurationObserver: NSObjectProtocol?

    func start() async throws {
        guard await Self.hasPermission() else { throw CallRecordingError.microphoneDenied }
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            flog("MicSource: voice processing unavailable (\(error)), recording the raw microphone")
            stopEngine()
            try startEngine(voiceProcessing: false)
        }
    }

    func stop() {
        stopEngine()
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        self.voiceProcessing = voiceProcessing
        resampler = MonoResampler()

        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                // Voice processing ducks other apps by default — here that would
                // be the call itself.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        // Voice processing runs through the output unit too; it needs the graph.
        _ = engine.mainMixerNode

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CallRecordingError.captureFailed("no input device")
        }
        let resampler = self.resampler
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, when in
            let samples = resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            self?.onChunk?(samples, when.isHostTimeValid ? when.hostTime : mach_absolute_time())
        }
        engine.prepare()
        try engine.start()

        // Plugging in headphones mid-call reconfigures the engine and stops it.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
        flog("MicSource: started, voiceProcessing=\(voiceProcessing), format=\(format)")
    }

    /// Only when the engine actually stopped: enabling voice processing and
    /// starting the graph post this notification themselves, and restarting on
    /// those would loop.
    private func restart() {
        guard let engine, !engine.isRunning else { return }
        let voiceProcessing = self.voiceProcessing
        stopEngine()
        do {
            try startEngine(voiceProcessing: voiceProcessing)
            return
        } catch {
            flog("MicSource: restart after configuration change failed: \(error)")
        }
        // Same fallback as `start()`: the raw microphone beats no microphone.
        guard voiceProcessing else {
            onEnded?(LocalizedMessage("call.error.captureFailed", "microphone restart failed"))
            return
        }
        stopEngine()
        do {
            try startEngine(voiceProcessing: false)
        } catch {
            onEnded?(LocalizedMessage("call.error.captureFailed", error.localizedDescription))
        }
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private static func hasPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
    }
}
