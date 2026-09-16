import AppKit
import CoreAudio

/// The apps a call can be recorded from.
enum AudioAppCatalog {

    /// Running apps: the one used last first, then those playing audio right
    /// now, then the rest by name. Background agents are listed only while they
    /// play audio.
    static func apps(lastUsed: String?) -> [CallApp] {
        let own = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return id != own && $0.activationPolicy != .prohibited
        }

        var playing: Set<String> = []
        if #available(macOS 14.2, *) {
            for process in CoreAudioProcesses.all() where process.isRunningOutput {
                let name = NSRunningApplication(processIdentifier: process.pid)?.localizedName
                for app in running {
                    let candidate = CallApp(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
                    if belongs(bundleID: process.bundleID, processName: name, to: candidate) {
                        playing.insert(candidate.bundleID)
                    }
                }
            }
        }

        var seen: Set<String> = []
        var apps: [CallApp] = []
        for app in running {
            guard let id = app.bundleIdentifier, !seen.contains(id) else { continue }
            guard app.activationPolicy == .regular || playing.contains(id) else { continue }
            seen.insert(id)
            apps.append(CallApp(bundleID: id, name: app.localizedName ?? id, isPlayingAudio: playing.contains(id)))
        }

        return apps.sorted { a, b in
            if (a.bundleID == lastUsed) != (b.bundleID == lastUsed) { return a.bundleID == lastUsed }
            if a.isPlayingAudio != b.isPlayingAudio { return a.isPlayingAudio }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Whether a process plays audio on behalf of `app`.
    ///
    /// Helpers carry the app's bundle ID as a prefix (`com.google.Chrome.helper`).
    /// WebKit's GPU process does not; it is named after the app it serves
    /// ("Safari Graphics and Media").
    static func belongs(bundleID: String, processName: String?, to app: CallApp) -> Bool {
        guard !app.bundleID.isEmpty else { return false }
        if bundleID == app.bundleID || bundleID.hasPrefix(app.bundleID + ".") { return true }
        if bundleID.hasPrefix("com.apple.WebKit"), !app.name.isEmpty,
           let processName, processName.hasPrefix(app.name + " ") {
            return true
        }
        return false
    }

    static func icon(for app: CallApp, size: CGFloat = 16) -> NSImage? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first,
              let icon = running.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}

/// Core Audio's audio clients: every process that has opened audio, and which
/// of them are playing.
@available(macOS 14.2, *)
enum CoreAudioProcesses {

    struct Entry {
        let id: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    static func all() -> [Entry] {
        CoreAudioProperty.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { id in
            Entry(id: id,
                  pid: CoreAudioProperty.value(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                  bundleID: CoreAudioProperty.string(id, kAudioProcessPropertyBundleID) ?? "",
                  isRunningOutput: (CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
        }
    }

    static func processes(of app: CallApp) -> [Entry] {
        all().filter {
            AudioAppCatalog.belongs(bundleID: $0.bundleID,
                                    processName: NSRunningApplication(processIdentifier: $0.pid)?.localizedName,
                                    to: app)
        }
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let device = CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject),
                                                   kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                   AudioObjectID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown
        else { return nil }
        return CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID)
    }
}

/// Global-scope Core Audio property reads.
enum CoreAudioProperty {

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// For plain value types only.
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
