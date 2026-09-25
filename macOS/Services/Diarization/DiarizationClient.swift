import Foundation

/// Runs the bundled `corvin-diarize` helper (Helpers/Diarizer) over decoded
/// audio and returns who spoke when.
///
/// A separate process rather than a library: FluidAudio needs macOS 14 while
/// Corvin targets 11, and Swift will not import a module built for a newer
/// system. The process boundary also contains FluidAudio's known macOS 14 BNNS
/// crash — it takes down the helper, not the app.
///
/// Local only. The helper loads models from `modelsDirectory` and has no code
/// path that reaches the network; audio goes to it through a temporary file.
enum DiarizationClient {

    /// Layout of the models directory the bundled helper can read. Manifest
    /// entries declaring another value are ignored, so a model update that
    /// needs a newer helper never reaches an older build.
    /// 1 — pyannote (Segmentation/FBank/Embedding/PLDA); 2 — Nemotron 3.
    static let helperAPI = 2

    enum DiarizationError: LocalizedError {
        case unsupportedSystem
        case helperMissing
        case modelsMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: return "diarization.error.unsupportedSystem".localized
            case .helperMissing: return "diarization.error.helperMissing".localized
            case .modelsMissing: return "diarization.error.modelsMissing".localized
            case .failed(let detail): return "diarization.error.failed".localized(with: detail)
            }
        }
    }

    static var isSupportedSystem: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// `Contents/Helpers/corvin-diarize` in the app bundle. A `swift build`
    /// binary has no bundle, so development runs point `CORVIN_DIARIZE_PATH`
    /// at `Helpers/Diarizer/.build/release/corvin-diarize`.
    static var helperURL: URL? {
        if let override = ProcessInfo.processInfo.environment["CORVIN_DIARIZE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/corvin-diarize")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    /// - Parameters:
    ///   - pcm: 16 kHz mono Int16, as `AudioFileDecoder.decode` returns it.
    ///   - onProgress: `(done, total)` 30 s audio blocks, off the main thread.
    ///   - shouldCancel: polled every 100 ms; the helper is terminated once it
    ///     returns true, and the call throws `CancellationError`.
    static func diarize(pcm: Data,
                        modelsDirectory: URL,
                        onProgress: ((Int, Int) -> Void)? = nil,
                        shouldCancel: @escaping () -> Bool) async throws -> [SpeakerSegment] {
        guard isSupportedSystem else { throw DiarizationError.unsupportedSystem }
        guard let helper = helperURL else { throw DiarizationError.helperMissing }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let segments = try run(helper: helper, pcm: pcm, modelsDirectory: modelsDirectory,
                                           onProgress: onProgress, shouldCancel: shouldCancel)
                    continuation.resume(returning: segments)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Process

    /// Exit codes of `corvin-diarize` (see its main.swift).
    private static let exitModelsMissing: Int32 = 65

    private static func run(helper: URL, pcm: Data, modelsDirectory: URL,
                            onProgress: ((Int, Int) -> Void)?,
                            shouldCancel: @escaping () -> Bool) throws -> [SpeakerSegment] {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("corvin-diarize-\(UUID().uuidString).f32")
        try writeFloat32(pcm, to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let process = Process()
        process.executableURL = helper
        process.arguments = ["--models", modelsDirectory.path, "--raw", input.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drained as it arrives: a long meeting's segment list is far larger
        // than a pipe buffer, and a helper blocked on a full pipe never exits.
        let output = LineCollector { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let done = object["progress"] as? Int, let total = object["total"] as? Int
            else { return }
            onProgress?(done, total)
        }
        let errors = LineCollector { _ in }
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }

        try process.run()
        flog("DiarizationClient: started helper pid \(process.processIdentifier), \(pcm.count / 2) samples")

        var cancelled = false
        while process.isRunning {
            if !cancelled, shouldCancel() {
                cancelled = true
                process.terminate()
                flog("DiarizationClient: cancelled, helper terminated")
            }
            usleep(100_000)
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errors.append(stderr.fileHandleForReading.readDataToEndOfFile())

        if cancelled { throw CancellationError() }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = errors.text.trimmingCharacters(in: .whitespacesAndNewlines)
            flog("DiarizationClient: helper failed (\(process.terminationReason == .exit ? "exit" : "signal") \(process.terminationStatus)): \(detail)")
            if process.terminationReason == .exit, process.terminationStatus == exitModelsMissing {
                throw DiarizationError.modelsMissing
            }
            throw DiarizationError.failed(detail.isEmpty ? "code \(process.terminationStatus)" : detail)
        }

        guard let segments = output.lines.lazy.compactMap(parseSegments).last else {
            throw DiarizationError.failed("no result")
        }
        flog("DiarizationClient: \(segments.count) segments, \(Set(segments.map(\.speaker)).count) speakers")
        return segments
    }

    private static func parseSegments(_ line: Data) -> [SpeakerSegment]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let raw = object["segments"] as? [[String: Any]] else { return nil }
        return raw.compactMap { entry in
            guard let speaker = entry["speaker"] as? String,
                  let start = entry["start"] as? Double,
                  let end = entry["end"] as? Double else { return nil }
            return SpeakerSegment(speaker: speaker, start: start, end: end)
        }
    }

    /// Int16 PCM → the helper's `--raw` format, Float32 little-endian.
    private static func writeFloat32(_ pcm: Data, to url: URL) throws {
        let floats: [Float] = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url)
    }
}

/// Accumulates a pipe's bytes and hands out complete lines. Filled from the
/// pipe's reader thread, read from the waiting one.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var complete: [Data] = []
    private let onLine: (Data) -> Void

    init(onLine: @escaping (Data) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var finished: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            finished.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        complete += finished
        lock.unlock()
        finished.forEach(onLine)
    }

    var lines: [Data] {
        lock.lock(); defer { lock.unlock() }
        return buffer.isEmpty ? complete : complete + [buffer]
    }

    var text: String {
        String(decoding: Data(lines.joined(separator: [0x0A])), as: UTF8.self)
    }
}
