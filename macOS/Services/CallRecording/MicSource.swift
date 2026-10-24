import AVFoundation

/// The user's side of a call: the default microphone, as it is.
///
/// No voice processing: the call app (Telegram, Zoom, Chrome's WebRTC) runs its
/// own on the same microphone, and a second voice-processing unit on that
/// device left the call app with silence — colleagues stopped hearing the user
/// the moment recording started. Without headphones the other side therefore
/// leaks into this channel; `EchoFilter` drops it. Its own `AVAudioEngine`, so
/// hotkey dictation keeps working during a call.
@available(macOS 13.0, *)
final class MicSource: CallAudioSource {
    var onChunk: (([Float], UInt64) -> Void)?
    var onWarning: ((LocalizedMessage) -> Void)?
    var onEnded: ((LocalizedMessage) -> Void)?

    private var engine: AVAudioEngine?
    private var resampler = MonoResampler()
    private var configurationObserver: NSObjectProtocol?

    func start() async throws {
        guard await Self.hasPermission() else { throw CallRecordingError.microphoneDenied }
        try startEngine()
    }

    func stop() {
        stopEngine()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        resampler = MonoResampler()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CallRecordingError.captureFailed("no input device")
        }
        let resampler = self.resampler
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, when in
            let samples = resampler.convert(buffer, mixdown: .average)
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
        flog("MicSource: started, format=\(format)")
    }

    /// Only when the engine actually stopped: starting the graph posts this
    /// notification itself, and restarting on that would loop.
    private func restart() {
        guard let engine, !engine.isRunning else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            flog("MicSource: restart after configuration change failed: \(error)")
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
