import AVFoundation
import CoreAudio

/// The other side of a call: a chosen app's audio through a Core Audio process
/// tap (macOS 14.2+).
///
/// The tap mixes every process the app owns down to stereo and feeds a private
/// aggregate device, whose IO proc hands the buffers over. Nothing is muted;
/// the user keeps hearing the call.
///
/// A tap has no permission preflight. The first start shows the system prompt,
/// and a denied tap simply delivers silence, so silence while Core Audio says
/// the app is playing is reported as a warning.
///
/// Every method except the IO callback is called on the main queue, by
/// `CallRecorder` or by the property listeners installed here.
@available(macOS 14.2, *)
final class ProcessTapSource: CallAudioSource {
    var onChunk: (([Float], UInt64) -> Void)?
    var onWarning: ((LocalizedMessage) -> Void)?
    var onEnded: ((LocalizedMessage) -> Void)?

    /// How long silence may last while the app is playing before it is taken
    /// for a denied permission.
    static let silenceGrace: TimeInterval = 4

    private let app: CallApp
    private let ioQueue = DispatchQueue(label: "com.corvin.call.tap", qos: .userInteractive)
    private var reader: TapReader?
    private var tapDescription: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var outputDeviceUID: String?
    private var tapped: Set<AudioObjectID> = []
    private var warned = false
    private var stopped = false

    init(app: CallApp) {
        self.app = app
    }

    func start() async throws {
        try open()
        watchProcesses()
        watchOutputDevice()
        scheduleSilenceCheck()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        removeListeners()
        close()
    }

    // MARK: - Tap

    /// Synchronous on purpose: rebuilding the tap when the output device
    /// changes must not interleave with `stop()` on another thread.
    private func open() throws {
        let processes = CoreAudioProcesses.processes(of: app)
        // An app that has not played a sound since it launched owns no Core
        // Audio process object yet, and recording is started before the call
        // is, not after: wait for the object rather than refusing. The tap is
        // opened by `processesChanged` as soon as one appears, and the other
        // channel is silence until then.
        guard !processes.isEmpty else {
            flog("ProcessTapSource: \(app.bundleID) has no audio process yet, waiting for one")
            return
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.id))
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        tapDescription = description
        tapped = Set(processes.map(\.id))

        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        guard let outputUID = CoreAudioProcesses.defaultOutputDeviceUID() else {
            throw CallRecordingError.captureFailed("no output device")
        }
        outputDeviceUID = outputUID
        // The output device is the clock source only. Listing it as a
        // sub-device would add its own input streams to the aggregate — a USB
        // headset's microphone would arrive mixed in with the app's audio.
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Corvin Call",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        guard var streamDescription = CoreAudioProperty.value(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              let format = AVAudioFormat(streamDescription: &streamDescription)
        else { throw CallRecordingError.captureFailed("tap format unavailable") }

        let reader = TapReader(format: format) { [weak self] samples, hostTime in
            self?.onChunk?(samples, hostTime)
        }
        self.reader = reader

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
            reader.read(input, time: inputTime.pointee)
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        flog("ProcessTapSource: tapping \(processes.map(\.bundleID)) as \(format)")
    }

    private func close() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDescription = nil
        reader = nil
    }

    // MARK: - Following the system

    /// Browsers and Electron apps start audio helper processes mid-call; the
    /// tap has to follow them.
    private func watchProcesses() {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.processesChanged()
        }
        processListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func processesChanged() {
        guard !stopped else { return }
        let current = Set(CoreAudioProcesses.processes(of: app).map(\.id))
        guard !current.isEmpty, current != tapped else { return }

        guard let tapDescription else {
            // The app was silent when recording started, so there was nothing
            // to tap yet. This is that moment.
            do {
                try open()
            } catch {
                flog("ProcessTapSource: opening the tap once \(app.bundleID) had audio failed: \(error)")
                onEnded?((error as? CallRecordingError)?.message
                         ?? LocalizedMessage("call.error.captureFailed", error.localizedDescription))
            }
            return
        }

        tapDescription.processes = Array(current)
        var address = CoreAudioProperty.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(tapDescription)
        let status = withUnsafeMutableBytes(of: &reference) { bytes in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        }
        if status == noErr {
            tapped = current
            flog("ProcessTapSource: now tapping \(current.count) process(es) of \(app.bundleID)")
        } else {
            flog("ProcessTapSource: could not update the tap: \(status)")
        }
    }

    /// The aggregate device is built around one output device. Unplugging a
    /// headset mid-call would otherwise stop it silently, and the other side
    /// would be silence for the rest of the call.
    private func watchOutputDevice() {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.outputDeviceChanged()
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func outputDeviceChanged() {
        guard !stopped,
              let current = CoreAudioProcesses.defaultOutputDeviceUID(),
              current != outputDeviceUID
        else { return }
        flog("ProcessTapSource: output device changed, rebuilding the tap")
        close()
        do {
            try open()
        } catch {
            flog("ProcessTapSource: rebuild failed: \(error)")
            onEnded?((error as? CallRecordingError)?.message
                     ?? LocalizedMessage("call.error.captureFailed", error.localizedDescription))
        }
    }

    private func removeListeners() {
        var processAddress = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        if let processListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &processAddress, .main, processListener)
            self.processListener = nil
        }
        var outputAddress = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &outputAddress, .main, outputListener)
            self.outputListener = nil
        }
    }

    private func scheduleSilenceCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceGrace) { [weak self] in
            guard let self, !self.stopped, !self.warned, self.reader?.heardSound.value != true else { return }
            if CoreAudioProcesses.processes(of: self.app).contains(where: \.isRunningOutput) {
                flog("ProcessTapSource: \(self.app.bundleID) is playing but the tap hears silence")
                self.warned = true
                self.onWarning?(LocalizedMessage("call.warning.noSystemAudio", self.app.name))
            } else {
                self.scheduleSilenceCheck()
            }
        }
    }

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw CallRecordingError.captureFailed("\(call) \(status)") }
    }
}

/// Turns the aggregate device's buffers into 16 kHz mono chunks, on the IO
/// thread and away from anything the main queue touches.
@available(macOS 14.2, *)
private final class TapReader: @unchecked Sendable {
    let heardSound = AtomicFlag()

    private let format: AVAudioFormat
    private let deliver: ([Float], UInt64) -> Void
    private let resampler = MonoResampler()
    /// The tap's own buffers, copied here each callback: the aggregate may
    /// carry more than the tap's, and the tap's come last.
    private let scratch: UnsafeMutableAudioBufferListPointer
    private let expected: Int

    init(format: AVAudioFormat, deliver: @escaping ([Float], UInt64) -> Void) {
        self.format = format
        self.deliver = deliver
        expected = format.isInterleaved ? 1 : Int(format.channelCount)
        scratch = AudioBufferList.allocate(maximumBuffers: expected)
    }

    deinit {
        free(scratch.unsafeMutablePointer)
    }

    func read(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        let incoming = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard incoming.count >= expected else { return }
        for index in 0..<expected {
            scratch[index] = incoming[incoming.count - expected + index]
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: scratch.unsafePointer, deallocator: nil)
        else { return }

        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        if !heardSound.value, samples.contains(where: { abs($0) > 1e-4 }) {
            heardSound.value = true
        }
        deliver(samples, time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time())
    }
}
