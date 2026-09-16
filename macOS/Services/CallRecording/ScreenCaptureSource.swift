import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// The other side of a call through ScreenCaptureKit, for macOS 13–14.1 where
/// process taps do not exist.
///
/// Needs the Screen Recording permission, even though only audio is used.
/// ScreenCaptureKit cannot capture audio alone, so the stream carries a 2×2
/// video frame once a second that nobody reads.
@available(macOS 13.0, *)
final class ScreenCaptureSource: NSObject, CallAudioSource, SCStreamOutput, SCStreamDelegate {
    var onChunk: (([Float], UInt64) -> Void)?
    var onWarning: ((LocalizedMessage) -> Void)?
    var onEnded: ((LocalizedMessage) -> Void)?

    private let app: CallApp
    private let resampler = MonoResampler()
    private let sampleQueue = DispatchQueue(label: "com.corvin.call.screencapture", qos: .userInteractive)
    private var stream: SCStream?

    init(app: CallApp) {
        self.app = app
        super.init()
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CallRecordingError.screenCaptureDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications.filter {
            AudioAppCatalog.belongs(bundleID: $0.bundleIdentifier, processName: $0.applicationName, to: app)
        }
        guard let display = content.displays.first, !apps.isEmpty else {
            throw CallRecordingError.appNotFound(app.name)
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        flog("ScreenCaptureSource: capturing \(apps.map(\.bundleIdentifier))")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              var streamDescription = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &streamDescription)
        else { return }
        // Presentation times are on the host clock, like the microphone's.
        let hostTime = AVAudioTime.hostTime(forSeconds: sampleBuffer.presentationTimeStamp.seconds)
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { onChunk?(samples, hostTime) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        flog("ScreenCaptureSource: stopped with error: \(error)")
        onEnded?(LocalizedMessage("call.error.captureFailed", error.localizedDescription))
    }
}
