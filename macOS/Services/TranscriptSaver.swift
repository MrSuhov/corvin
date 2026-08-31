import Foundation

/// Writes transcripts to disk and answers, up front, whether it will be able to.
///
/// Corvin is unsandboxed, so reading a file the user picked or dragged is never
/// a problem. Creating a *sibling* `.txt` is a different matter: TCC guards
/// Desktop / Documents / Downloads / removable and network volumes by category,
/// and the read grant that comes with a user-picked file does not extend to
/// making a new file beside it.
enum TranscriptSaver {

    /// Why a directory can't be written to. The distinction drives which
    /// buttons the permission alert offers — "Open Settings" is useless advice
    /// for a read-only DMG.
    enum WriteAccess: Equatable {
        case ok
        /// Blocked by TCC. Recoverable: grant the folder, or pick another one.
        case tccDenied
        /// The volume itself is read-only. No permission dialog will help.
        case readOnlyVolume
        /// POSIX permissions, missing directory, or anything else.
        case other(String)
    }

    /// Probing must never run on the main thread: the TCC check is a synchronous
    /// XPC round trip to `tccd` that blocks the caller for as long as the consent
    /// dialog is up. Serial so two prompts can't stack on top of each other.
    static let probeQueue = DispatchQueue(label: "com.corvin.transcript-saver.probe")

    /// TCC grants are category-wide, so one answer per directory is plenty and
    /// re-probing a granted folder just burns an XPC round trip.
    private static var probeCache: [URL: WriteAccess] = [:]
    private static let cacheLock = NSLock()

    // MARK: - Probing

    /// Attempt an actual create-and-delete. There is no cheaper way to find out:
    /// `FileManager.isWritableFile(atPath:)` and `URL.isWritableKey` both bottom
    /// out in `access(2)`, which TCC does not intercept — they cheerfully return
    /// `true` for a blocked Desktop and never surface the consent prompt. Only a
    /// real `open(2)` for writing does.
    ///
    /// Must be called off the main thread. See `probeQueue`.
    static func probe(_ directory: URL) -> WriteAccess {
        let key = directory.standardizedFileURL

        cacheLock.lock()
        let cached = probeCache[key]
        cacheLock.unlock()
        if let cached { return cached }

        let result = uncachedProbe(key)

        cacheLock.lock()
        probeCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func uncachedProbe(_ directory: URL) -> WriteAccess {
        let probeURL = directory.appendingPathComponent(".corvin-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL, options: [.withoutOverwriting])
            try? FileManager.default.removeItem(at: probeURL)
            return .ok
        } catch let error as NSError {
            flog("TranscriptSaver: probe failed for \(directory.path): \(error.domain) \(error.code)")
            return classify(error)
        }
    }

    private static func classify(_ error: NSError) -> WriteAccess {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteVolumeReadOnlyError {
            return .readOnlyVolume
        }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError {
            // TCC surfaces as EPERM; a plain permission-bits problem is EACCES.
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            if underlying?.domain == NSPOSIXErrorDomain, underlying?.code == Int(EPERM) {
                return .tccDenied
            }
            // No underlying error at all is the common shape of a TCC denial too.
            if underlying == nil { return .tccDenied }
        }
        return .other(error.localizedDescription)
    }

    /// Probe a set of directories, deduplicated, on `probeQueue`.
    /// Reports back on the main queue.
    static func probeAll(_ directories: Set<URL>, completion: @escaping ([URL: WriteAccess]) -> Void) {
        probeQueue.async {
            var results: [URL: WriteAccess] = [:]
            for directory in directories {
                results[directory.standardizedFileURL] = probe(directory)
            }
            DispatchQueue.main.async { completion(results) }
        }
    }

    /// Drop cached answers so a folder the user has just granted in System
    /// Settings is re-checked instead of staying permanently red.
    static func forgetProbeResults() {
        cacheLock.lock()
        probeCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Writing

    /// Never TCC-gated and always writable — where transcripts land when the
    /// intended directory refuses them.
    static var fallbackDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Corvin/Transcripts", isDirectory: true)
    }

    /// Write `text` as `<audio basename>.txt` in `directory`, adding `_1`, `_2`, …
    /// until the name is free. Returns the URL actually written.
    @discardableResult
    static func write(text: String, audioName: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // UTF-8, LF, one trailing newline, no BOM.
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if !body.hasSuffix("\n") { body += "\n" }
        let data = Data(body.utf8)

        let base = safeBaseName(from: audioName)

        for index in 0...999 {
            let name = index == 0 ? "\(base).txt" : "\(base)_\(index).txt"
            let candidate = directory.appendingPathComponent(name)
            do {
                // `.withoutOverwriting` is the whole point and it cannot be
                // combined with `.atomic` — an atomic write stages a temp file
                // and renames over the destination, which clobbers.
                try data.write(to: candidate, options: [.withoutOverwriting])
                flog("TranscriptSaver: wrote \(candidate.path)")
                return candidate
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue  // name taken, try the next suffix
            }
            // Anything else — permissions, full disk — is not a collision and
            // must not be retried 999 times under a different name.
        }

        // Absurd number of collisions: fall back to a name that cannot collide.
        let unique = directory.appendingPathComponent("\(base)_\(UUID().uuidString.prefix(8)).txt")
        try data.write(to: unique, options: [.withoutOverwriting])
        return unique
    }

    /// Trim the basename so that basename + "_999.txt" still fits the 255-byte
    /// filename limit on APFS/HFS+.
    private static func safeBaseName(from audioName: String) -> String {
        let stem = (audioName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "transcript" : stem
        let budget = 255 - "_999.txt".utf8.count

        var trimmed = base
        while trimmed.utf8.count > budget, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "transcript" : trimmed
    }
}
