import AVFoundation
import UIKit
import Combine

/// Keeps the host process unsuspended so the keyboard extension can always reach
/// the local IPC server.
///
/// Two independent layers hold the process:
///  1. A continuously looping near-silent `AVAudioPlayer` under `UIBackgroundModes: audio`.
///     Nothing but an audio interruption can take this away, and interruptions are recovered.
///  2. Picture-in-Picture (`PiPService`), which any other app can steal — it is now a
///     secondary layer and a visible indicator, no longer the single point of failure.
///
/// This service also owns the shared `AVAudioSession` configuration, which used to live
/// inside `PiPService` — a failure there must not prevent PiP from being created.
@MainActor
final class BackgroundKeepAliveService: NSObject, ObservableObject {
    static let shared = BackgroundKeepAliveService()

    /// User intent, persisted across launches in the App Group.
    /// This is what the "Работа в фоне" toggle binds to.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: SharedDefaults.backgroundModeEnabled)
            flog("KeepAlive: isEnabled = \(isEnabled)")
            apply()
        }
    }

    /// True while the silent player is actually rendering audio.
    @Published private(set) var isHoldingProcess = false
    /// Held as a key, not as finished text: this banner stays on screen, so a
    /// language switch has to re-render it rather than freeze the old language.
    @Published private(set) var errorMessage: LocalizedMessage?

    private let defaults: UserDefaults

    private var player: AVAudioPlayer?
    private var watchdog: DispatchSourceTimer?
    private var isRecording = false
    private var isKeyboardActive = false
    /// Between interruption began and ended the session belongs to someone else (a call).
    private var isInterrupted = false

    /// Called when the keyboard announces itself, so the app can warm the model up.
    var onKeyboardBecameActive: (() -> Void)?

    private override init() {
        defaults = UserDefaults(suiteName: SharedDefaults.appGroup) ?? .standard
        isEnabled = defaults.bool(forKey: SharedDefaults.backgroundModeEnabled)
        super.init()
        registerObservers()
        flog("KeepAlive init, persisted isEnabled=\(isEnabled)")
        // Restore background mode automatically on launch — the user should never
        // have to hunt for the toggle again.
        if isEnabled { apply() }
    }

    // MARK: - Audio session (owner)

    /// The session stays active for as long as background mode is on, so it must not look
    /// like a call to the rest of the system:
    ///  - `.default` mode, not `.voiceChat`: voice chat ducks every other app's audio and
    ///    moves the volume buttons to call volume — videos played muted while Corvin lived.
    ///  - A2DP and AirPlay, not HFP: with HFP allowed, Bluetooth headphones dropped to the
    ///    headset profile and music could not be sent to Bluetooth or AirPlay at all.
    ///    Dictation records from the built-in mic while headphones keep playing.
    /// `.playAndRecord` itself stays: a session that cannot record cannot start recording
    /// from the background, which is when the keyboard asks for it.
    private static let options: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]

    /// Configures the unified session used by both PiP playback and mic capture.
    /// Idempotent; safe to call repeatedly.
    @discardableResult
    func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // Re-setting an unchanged category still re-routes, so skip it when nothing differs.
            if session.category != .playAndRecord || session.mode != .default
                || session.categoryOptions != Self.options {
                try session.setCategory(.playAndRecord, mode: .default, options: Self.options)
            }
            try session.setActive(true)
            errorMessage = nil
            flog("KeepAlive: audio session playAndRecord/default active")
            return true
        } catch {
            flog("KeepAlive: audio session error: \(error)")
            errorMessage = LocalizedMessage("background.error.audio", error.localizedDescription)
            return false
        }
    }

    // MARK: - Public API

    /// Applies the current intent to both keep-alive layers.
    private func apply() {
        if isEnabled {
            configureAudioSession()
            startSilentPlayer()
            startWatchdog()
            PiPService.shared.setMaintain(true)
        } else {
            stopSilentPlayer()
            stopWatchdog()
            PiPService.shared.setMaintain(false)
            clearAliveBeacon()
        }
    }

    /// Re-assert everything. Called on `didBecomeActive`, on keyboard appearance,
    /// after an interruption and after a media services reset.
    func revive(reason: String) {
        guard isEnabled else { return }
        flog("KeepAlive: revive (\(reason))")
        // Never touch the session mid-capture: reconfiguring it would cut the recording short.
        if !isRecording {
            if !otherAppOwnsAudio { configureAudioSession() }
            startSilentPlayer()
        }
        startWatchdog()
        PiPService.shared.setMaintain(true)
    }

    /// The mic is about to be used. The capture itself sustains background execution,
    /// and the filler signal must not end up in the recording, so it is paused.
    func setRecording(_ recording: Bool) {
        guard isRecording != recording else { return }
        isRecording = recording
        flog("KeepAlive: setRecording(\(recording))")
        if recording {
            player?.pause()
            isHoldingProcess = false
        } else if isEnabled {
            // Deliberately no setCategory/setActive here — the host is still tearing the
            // capture engine down. startSilentPlayer() falls back to reconfiguring the
            // session only if playback actually fails.
            startSilentPlayer()
        }
    }

    /// Keyboard presence, reported over IPC. Drives the low-power idle mode.
    func setKeyboardActive(_ active: Bool) {
        guard isKeyboardActive != active else { return }
        isKeyboardActive = active
        flog("KeepAlive: keyboard \(active ? "active" : "inactive")")
        PiPService.shared.setIdle(!active)
        if active {
            revive(reason: "keyboard appeared")
            onKeyboardBecameActive?()
        }
    }

    // MARK: - Silent player

    private func startSilentPlayer() {
        guard isEnabled, !isRecording else { return }

        if let player = player, player.isPlaying {
            isHoldingProcess = true
            return
        }

        if player == nil {
            guard let url = makeQuietLoopFile() else {
                errorMessage = LocalizedMessage("background.error.setupFailed")
                return
            }
            do {
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.numberOfLoops = -1
                // ±1 LSB samples at 0.5% volume — roughly -135 dBFS, inaudible,
                // but not digital silence (some iOS builds suspend on pure zeros).
                newPlayer.volume = 0.005
                newPlayer.prepareToPlay()
                player = newPlayer
            } catch {
                flog("KeepAlive: player init failed: \(error)")
                errorMessage = LocalizedMessage("background.error.generic", error.localizedDescription)
                return
            }
        }

        let started = player?.play() ?? false
        isHoldingProcess = started
        flog("KeepAlive: silent player play() -> \(started)")
        if !started, !otherAppOwnsAudio {
            // The session was probably deactivated under us; re-arm and retry once.
            configureAudioSession()
            isHoldingProcess = player?.play() ?? false
        }
    }

    private func stopSilentPlayer() {
        player?.stop()
        player = nil
        isHoldingProcess = false
        flog("KeepAlive: silent player stopped")
    }

    /// Writes a 1-second 16-bit mono 44.1 kHz WAV of ±1 LSB dither.
    /// Generated in code so no binary asset has to ship.
    private func makeQuietLoopFile() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corvin-keepalive.wav")

        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44100
        let frames = sampleRate
        let bytesPerSample = 2
        let dataBytes = frames * bytesPerSample

        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * bytesPerSample))
        le16(UInt16(bytesPerSample)); le16(16)
        ascii("data"); le32(UInt32(dataBytes))

        for i in 0..<frames {
            let sample: Int16 = (i % 2 == 0) ? 1 : -1
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        do {
            try data.write(to: url, options: .atomic)
            flog("KeepAlive: generated keep-alive tone (\(data.count) bytes)")
            return url
        } catch {
            flog("KeepAlive: failed to write keep-alive tone: \(error)")
            return nil
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: [], queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.watchdogTick() }
        }
        timer.resume()
        watchdog = timer
        flog("KeepAlive: watchdog started")
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        flog("KeepAlive: watchdog stopped")
    }

    private func watchdogTick() {
        guard isEnabled else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: SharedDefaults.hostAliveAt)

        guard !isRecording else { return }
        if player?.isPlaying != true {
            flog("KeepAlive: watchdog found player stopped, restarting")
            if !otherAppOwnsAudio { configureAudioSession() }
            startSilentPlayer()
        } else {
            isHoldingProcess = true
        }
    }

    /// Someone else's call or primary audio holds the route. Re-asserting our session then
    /// (setCategory/setActive) fights it for the route — that is how a Telegram call switched
    /// to headphones went silent. The player may still be restarted: play() leaves the route alone.
    private var otherAppOwnsAudio: Bool {
        if isInterrupted { return true }
        let session = AVAudioSession.sharedInstance()
        if session.secondaryAudioShouldBeSilencedHint {
            flog("KeepAlive: other app owns audio, leaving the session alone")
            return true
        }
        return false
    }

    private func clearAliveBeacon() {
        defaults.removeObject(forKey: SharedDefaults.hostAliveAt)
    }

    // MARK: - Session interruptions

    private func registerObservers() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            Task { @MainActor in
                BackgroundKeepAliveService.shared.handleInterruption(note)
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            Task { @MainActor in
                BackgroundKeepAliveService.shared.handleRouteChange(note)
            }
        }

        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                BackgroundKeepAliveService.shared.handleMediaServicesReset()
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            flog("KeepAlive: audio interruption began")
            isInterrupted = true
            isHoldingProcess = false
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            flog("KeepAlive: audio interruption ended, shouldResume=\(options.contains(.shouldResume))")
            isInterrupted = false
            revive(reason: "interruption ended")
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard isEnabled, !isRecording else { return }
        if player?.isPlaying != true {
            flog("KeepAlive: route change stopped playback, restarting")
            revive(reason: "route change")
        }
    }

    private func handleMediaServicesReset() {
        flog("KeepAlive: media services were reset — rebuilding everything")
        player?.stop()
        player = nil
        isInterrupted = false
        guard isEnabled else { return }
        configureAudioSession()
        startSilentPlayer()
        PiPService.shared.rebuildAfterMediaServicesReset()
    }
}
