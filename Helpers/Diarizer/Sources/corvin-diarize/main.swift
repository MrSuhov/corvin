import FluidAudio
import Foundation

// corvin-diarize: speaker diarization for Corvin's file transcription, run as a
// separate process.
//
// Why a process and not a library: FluidAudio requires macOS 14, Corvin runs on
// macOS 11, and Swift refuses to import a module whose deployment target is
// higher than the importer's. A process also contains FluidAudio's known macOS
// 14 BNNS crash — it takes down this helper, not the app.
//
// Local only. Models are loaded from --models with Nemotron3Models.load; the
// FluidAudio loaders that download missing files from HuggingFace are never
// called, so nothing here can reach the network.
//
// Model: NVIDIA Nemotron 3 Diarization (8-speaker streaming Sortformer), the
// CoreML port from FluidInference/nemotron-3-diarization-coreml. The preset is
// whichever bundle --models holds (see `presets`); the store installs one.
//
// Usage:
//   corvin-diarize --models <dir> --raw <file>   16 kHz mono Float32 little-endian
//   corvin-diarize --models <dir> --audio <file> any AVFoundation format (debugging)
//
// stdout, one JSON object per line:
//   {"progress":3,"total":40}
//   {"segments":[{"speaker":"1","start":1.2,"end":4.8}],"seconds":2.1}
// Errors go to stderr with a non-zero exit code.

enum ExitCode: Int32 {
    case usage = 64
    case modelsMissing = 65
    case failed = 70
}

struct Options {
    var models: URL?
    var raw: URL?
    var audio: URL?
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

func parse(_ args: [String]) -> Options {
    var options = Options()
    var it = args.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("missing value for \(flag)", .usage) }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--models": options.models = URL(fileURLWithPath: value(arg), isDirectory: true)
        case "--raw": options.raw = URL(fileURLWithPath: value(arg))
        case "--audio": options.audio = URL(fileURLWithPath: value(arg))
        default: fail("unknown argument \(arg)", .usage)
        }
    }
    guard options.models != nil, (options.raw == nil) != (options.audio == nil) else {
        fail("usage: corvin-diarize --models <dir> (--raw <f32 16k mono> | --audio <file>)", .usage)
    }
    return options
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Presets the helper can run, most preferred first, keyed by the bundle the
/// store installed. `offline` sees 30 s at a time — latency is irrelevant for a
/// file; the split-graph preset is half the download at slightly higher DER.
let presets = ["offline", "c128-split-w8a8"]

/// Loads the installed preset from disk. `Nemotron3Models.load` reads only the
/// given directory; `loadFromHuggingFace` (the download path) is never called.
func loadDiarizer(from directory: URL) async throws -> Nemotron3Diarizer {
    let installed = presets.compactMap(Nemotron3Config.preset(named:)).first {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.modelFileName).path)
    }
    guard let config = installed else {
        fail("models missing in \(directory.path): no Nemotron 3 bundle", .modelsMissing)
    }
    var assets = [ModelNames.Nemotron3.silenceEmbeddingFile]
    if config.splitGraph { assets.append(ModelNames.Nemotron3.preEncodeProjectionFile) }
    let missing = assets.filter {
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
    guard missing.isEmpty else {
        fail("models missing in \(directory.path): \(missing.joined(separator: ", "))", .modelsMissing)
    }
    let models = try await Nemotron3Models.load(config: config, directory: directory)
    return Nemotron3Diarizer(config: config, models: models)
}

func readRawSamples(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return samples
}

let options = parse(CommandLine.arguments)

// Belt and braces: should anything inside FluidAudio still try to fetch a
// model, it throws instead of opening a connection.
ModelHub.offlineMode = true

/// Audio fed per streaming call; progress is reported once per block.
let blockSeconds = 30

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        let started = Date()
        let diarizer = try await loadDiarizer(from: options.models!)
        let audio = try options.raw.map(readRawSamples)
            ?? AudioConverter().resampleAudioFile(options.audio!)

        // The streaming path is frame-exact with processComplete but reports
        // progress; it costs nothing extra for a whole file.
        let block = blockSeconds * diarizer.config.sampleRate
        let total = max(1, (audio.count + block - 1) / block)
        var probabilities: [Float] = []
        var frames = 0
        func collect(_ results: [Nemotron3ChunkResult]) {
            for r in results {
                probabilities += r.probabilities
                frames += r.frameCount
            }
        }
        for (i, offset) in stride(from: 0, to: audio.count, by: block).enumerated() {
            diarizer.appendAudio(Array(audio[offset..<min(offset + block, audio.count)]))
            collect(try diarizer.processBufferedAudio())
            emit(["progress": i + 1, "total": total])
        }
        collect(try diarizer.finishStream())

        let segments = Nemotron3Diarizer.segments(
            probabilities: probabilities, frameCount: frames,
            numSpeakers: diarizer.config.numSpeakers)
        emit([
            "segments": segments.map {
                // Arrival order: the first voice heard is speaker 1.
                ["speaker": String($0.speakerIndex + 1),
                 "start": Double($0.startSeconds),
                 "end": Double($0.endSeconds)] as [String: Any]
            },
            "seconds": Date().timeIntervalSince(started),
        ])
    } catch {
        fail("diarization failed: \(error.localizedDescription)", .failed)
    }
}
semaphore.wait()
