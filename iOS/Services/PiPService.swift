import AVKit
import UIKit
import Combine

/// Manages Picture-in-Picture mode for background recording.
/// Uses AVSampleBufferDisplayLayer for live content (no playback controls).
@MainActor
class PiPService: NSObject, ObservableObject {
    static let shared = PiPService()

    @Published var isPiPActive = false
    @Published var isPiPPossible = false
    @Published var errorMessage: String?

    private var sampleBufferLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var pipWindow: UIWindow?
    private var containerView: UIView?
    private var frameTimer: DispatchSourceTimer?
    private var cachedPixelBuffer: CVPixelBuffer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastFramePushTime: Date?
    private var frameCount: Int64 = 0

    /// Whether background mode wants PiP up. Set by `BackgroundKeepAliveService`.
    private var shouldMaintain = false
    /// Distinguishes "we stopped it" from "another app stole it".
    private var userInitiatedStop = false
    private var restartAttempt = 0
    private var restartWorkItem: DispatchWorkItem?
    private var isIdle = false

    private let pipSize = CGSize(width: 600, height: 150)
    private let activeFrameIntervalMs = 500
    private let idleFrameIntervalMs = 1000
    /// Backoff schedule for reclaiming PiP after another app took it.
    private let restartDelays: [TimeInterval] = [0, 1, 3, 10, 30]

    private override init() {
        super.init()
        flog("PiPService init")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                self?.setupPiP()
            }
        }
    }

    private func setupPiP() {
        flog("PiP setup started")

        // The unified .playAndRecord/.voiceChat session is owned by BackgroundKeepAliveService —
        // both PiP playback and mic capture share it, and switching categories breaks PiP.
        // A session failure must NOT abort PiP setup: the two keep-alive layers are independent.
        if !BackgroundKeepAliveService.shared.configureAudioSession() {
            flog("PiP setup continuing despite audio session failure")
        }

        let isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        flog("PiP supported: \(isSupported)")

        guard isSupported else {
            errorMessage = "PiP не поддерживается"
            return
        }

        setupSampleBufferPiP()
    }

    private func setupSampleBufferPiP() {
        flog("Setting up SampleBuffer PiP...")

        // Create sample buffer display layer
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = CGRect(origin: .zero, size: pipSize)

        // Setup timebase (required for proper timing)
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let tb = timebase {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            layer.controlTimebase = tb
            flog("Timebase configured")
        }

        self.sampleBufferLayer = layer

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            flog("No window scene")
            errorMessage = "Нет окна"
            return
        }

        let containerView = UIView(frame: CGRect(origin: .zero, size: pipSize))
        containerView.backgroundColor = UIColor(red: 59/255, green: 130/255, blue: 246/255, alpha: 1)
        containerView.layer.addSublayer(layer)
        self.containerView = containerView

        let containerVC = UIViewController()
        containerVC.view = containerView

        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: pipSize)
        window.rootViewController = containerVC
        window.isHidden = false
        window.windowLevel = .normal - 1
        window.alpha = 0.01
        self.pipWindow = window

        // Create PiP controller with sample buffer source
        let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: contentSource)

        controller.delegate = self
        // Let the system re-enter PiP on its own whenever the app backgrounds,
        // so a stolen PiP recovers without the user touching anything.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller

        flog("PiP controller created")

        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let isPossible = change.newValue ?? false
            flog("PiP isPossible: \(isPossible)")
            Task { @MainActor in
                guard let self = self else { return }
                self.isPiPPossible = isPossible
                if isPossible {
                    self.errorMessage = nil
                    // PiP became available again (e.g. the other app released it).
                    if self.shouldMaintain && !self.isPiPActive {
                        self.startPiP()
                    }
                }
            }
        }

        // Start rendering frames
        startRenderingFrames()

        flog("PiP setup complete")

        // Background mode may already be on from a previous launch. PiP only becomes
        // "possible" once frames are flowing, so poll with backoff rather than assuming
        // the KVO will fire.
        if shouldMaintain && !isPiPActive {
            scheduleRestart()
        }
    }

    private func startRenderingFrames() {
        stopRenderingFrames()

        // Push initial frame immediately
        pushFrame()

        let intervalMs = isIdle ? idleFrameIntervalMs : activeFrameIntervalMs
        // Use DispatchSourceTimer instead of CADisplayLink for reliable background execution
        let timer = DispatchSource.makeTimerSource(flags: [], queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.pushFrameTick()
        }
        timer.resume()
        frameTimer = timer
        flog("Frame timer started (DispatchSourceTimer, \(intervalMs)ms interval)")
    }

    private func stopRenderingFrames() {
        guard frameTimer != nil else { return }
        frameTimer?.cancel()
        frameTimer = nil
        lastFramePushTime = nil
        flog("Frame timer stopped")
    }

    private func pushFrameTick() {
        let now = Date()
        // If gap is large we likely woke from suspension - notify to restart IPC.
        // Even short suspensions (10-20s) can leave NWListener in zombie state.
        if let last = lastFramePushTime {
            let gap = now.timeIntervalSince(last)
            if gap > 10 {
                flog("Frame push after gap: \(String(format: "%.1f", gap))s — posting restart notification")
                NotificationCenter.default.post(name: .pipWokeFromSuspension, object: nil)
            }
        }
        lastFramePushTime = now
        pushFrame()
    }

    private func pushFrame() {
        guard let layer = sampleBufferLayer else { return }

        // Check layer status and reset if failed
        let status = layer.status
        if status == .failed {
            flog("Layer status FAILED, error: \(layer.error?.localizedDescription ?? "unknown"), resetting...")
            layer.flush()
            // Reset timebase
            if let tb = layer.controlTimebase {
                CMTimebaseSetTime(tb, time: .zero)
                CMTimebaseSetRate(tb, rate: 1.0)
            }
            frameCount = 0
            cachedPixelBuffer = nil
        }

        // Use cached buffer or create new one
        let buffer: CVPixelBuffer
        if let cached = cachedPixelBuffer {
            buffer = cached
        } else if let newBuffer = createImagePixelBuffer() {
            cachedPixelBuffer = newBuffer
            buffer = newBuffer
        } else {
            return
        }

        // Create sample buffer from pixel buffer
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                      imageBuffer: buffer,
                                                      formatDescriptionOut: &formatDescription)

        guard let format = formatDescription else { return }

        // CRITICAL: Use incrementing frame count for timing, not timebase time
        // This ensures each frame has a unique, advancing presentation time
        frameCount += 1
        let presentationTime = CMTime(value: frameCount, timescale: 30)

        // Advance the timebase to match
        if let tb = layer.controlTimebase {
            CMTimebaseSetTime(tb, time: presentationTime)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2), // 0.5 second duration (matches timer interval)
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                  imageBuffer: buffer,
                                                  formatDescription: format,
                                                  sampleTiming: &timing,
                                                  sampleBufferOut: &sampleBuffer)

        if let sample = sampleBuffer {
            layer.enqueue(sample)
        }
    }

    private func createImagePixelBuffer() -> CVPixelBuffer? {
        // Load image from bundle
        guard let path = Bundle.main.path(forResource: "swipe_me", ofType: "png"),
              let image = UIImage(contentsOfFile: path),
              let cgImage = image.cgImage else {
            flog("Failed to load swipe_me.png from bundle")
            return nil
        }
        flog("Loaded swipe_me.png: \(cgImage.width)x\(cgImage.height)")

        let width = Int(pipSize.width)
        let height = Int(pipSize.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)

        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Draw white background first
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // High quality interpolation
        context.interpolationQuality = .high

        // Draw image scaled to fit
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    // MARK: - Public API

    /// Declares whether background mode wants PiP up.
    /// Owned by `BackgroundKeepAliveService`, which persists the user's intent.
    func setMaintain(_ maintain: Bool) {
        guard shouldMaintain != maintain else { return }
        shouldMaintain = maintain
        flog("PiP setMaintain(\(maintain))")
        if maintain {
            restartAttempt = 0
            startPiP()
        } else {
            stopPiP()
        }
    }

    /// Low-power mode while the keyboard is not on screen.
    func setIdle(_ idle: Bool) {
        guard isIdle != idle else { return }
        isIdle = idle
        flog("PiP setIdle(\(idle))")
        if frameTimer != nil {
            startRenderingFrames()
        }
    }

    func startPiP() {
        flog("startPiP")
        cancelPendingRestart()

        guard let controller = pipController else {
            // Setup has not finished yet; the isPictureInPicturePossible KVO will retry.
            flog("startPiP: controller not ready yet")
            return
        }
        guard !isPiPActive else { return }

        userInitiatedStop = false
        pipWindow?.isHidden = false
        if frameTimer == nil { startRenderingFrames() }

        if controller.isPictureInPicturePossible {
            flog("Starting PiP...")
            controller.startPictureInPicture()
        } else {
            flog("startPiP: not possible right now, scheduling retry")
            scheduleRestart()
        }
    }

    func stopPiP() {
        userInitiatedStop = true
        cancelPendingRestart()
        if isPiPActive {
            flog("Stopping PiP...")
            pipController?.stopPictureInPicture()
        }
        // Genuinely release resources — this used to leave the frame timer and the
        // hidden window running forever.
        stopRenderingFrames()
        pipWindow?.isHidden = true
    }

    /// Called when the app returns to the foreground. Cheap and idempotent.
    func reassertIfNeeded() {
        guard shouldMaintain, !isPiPActive else { return }
        flog("PiP reassert on foreground")
        restartAttempt = 0
        startPiP()
    }

    /// Full rebuild after `AVAudioSession.mediaServicesWereResetNotification`.
    func rebuildAfterMediaServicesReset() {
        flog("PiP rebuilding after media services reset")
        cancelPendingRestart()
        stopRenderingFrames()
        possibleObservation?.invalidate()
        possibleObservation = nil
        pipController = nil
        sampleBufferLayer = nil
        cachedPixelBuffer = nil
        frameCount = 0
        pipWindow?.isHidden = true
        pipWindow = nil
        containerView = nil
        isPiPActive = false
        isPiPPossible = false
        setupPiP()
    }

    func setRecording(_ recording: Bool) {
        flog("Recording: \(recording)")
        BackgroundKeepAliveService.shared.setRecording(recording)
        // When recording stops, refresh PiP to prevent black screen
        if !recording {
            refreshPiP()
        }
    }

    // MARK: - Restart backoff

    private func scheduleRestart() {
        guard shouldMaintain, !userInitiatedStop else { return }
        cancelPendingRestart()

        let delay = restartDelays[min(restartAttempt, restartDelays.count - 1)]
        restartAttempt += 1
        flog("PiP restart attempt \(restartAttempt) in \(delay)s")

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.restartWorkItem = nil
                guard self.shouldMaintain, !self.isPiPActive else { return }
                guard let controller = self.pipController else {
                    self.scheduleRestart()
                    return
                }
                if controller.isPictureInPicturePossible {
                    flog("PiP restart: possible, starting")
                    if self.frameTimer == nil { self.startRenderingFrames() }
                    controller.startPictureInPicture()
                } else {
                    flog("PiP restart: still not possible")
                    self.scheduleRestart()
                }
            }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    /// Refresh PiP frames after any potential disruption
    func refreshPiP() {
        flog("Refreshing PiP...")

        guard let layer = sampleBufferLayer else {
            flog("No sample buffer layer to refresh")
            return
        }

        // Check and log current status
        let status = layer.status
        let statusStr: String
        switch status {
        case .unknown: statusStr = "unknown"
        case .rendering: statusStr = "rendering"
        case .failed: statusStr = "failed"
        @unknown default: statusStr = "other"
        }
        flog("Layer status before refresh: \(statusStr)")

        // Clear cached buffer to force new frame creation
        cachedPixelBuffer = nil

        // Flush sample buffer layer
        layer.flush()

        // Reset timebase
        if let tb = layer.controlTimebase {
            frameCount = 0
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }

        // Push fresh frames with delays to ensure display
        pushFrame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pushFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pushFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pushFrame()
        }

        flog("PiP refreshed")
    }

    deinit {
        frameTimer?.cancel()
        frameTimer = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        possibleObservation?.invalidate()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
    }

    // MARK: - Background Task Management

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiP Frame Rendering") { [weak self] in
            flog("PiP background task expired")
            self?.endBackgroundTask()
        }
        flog("PiP background task started")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        flog("PiP background task ended")
    }
}

// MARK: - PiP Delegate

extension PiPService: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in flog("PiP will start") }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            flog("PiP started!")
            self.isPiPActive = true
            self.errorMessage = nil
            self.restartAttempt = 0
            self.cancelPendingRestart()
            self.beginBackgroundTask()
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in flog("PiP will stop") }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            self.endBackgroundTask()

            if self.shouldMaintain && !self.userInitiatedStop {
                // Another app claimed the system's single PiP window (or iOS dropped ours).
                // Not surfaced as an error: the silent-audio layer still holds the process,
                // so dictation keeps working while we wait to reclaim PiP.
                flog("PiP stopped externally — will try to reclaim")
                self.scheduleRestart()
            } else {
                flog("PiP stopped (user initiated)")
            }
        }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            // Expected while the app is backgrounded or another app holds PiP —
            // keep retrying quietly, the audio layer is what actually keeps us alive.
            flog("PiP failed: \(error)")
            self.isPiPActive = false
            self.scheduleRestart()
        }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            flog("PiP restore UI")
            completionHandler(true)
        }
    }
}

// MARK: - Sample Buffer Playback Delegate

// MARK: - Notifications

extension Notification.Name {
    static let pipWokeFromSuspension = Notification.Name("pipWokeFromSuspension")
}

// MARK: - Sample Buffer Playback Delegate

extension PiPService: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        flog("PiP setPlaying: \(playing) (ignored)")
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, end: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        return false
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        flog("PiP render size: \(newRenderSize.width)x\(newRenderSize.height)")
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
