import CoreML
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
// Local only. Models are loaded from --models with MLModel(contentsOf:); the
// FluidAudio loaders that download missing files from HuggingFace are never
// called, so nothing here can reach the network.
//
// Usage:
//   corvin-diarize --models <dir> --raw <file>   16 kHz mono Float32 little-endian
//   corvin-diarize --models <dir> --audio <file> any AVFoundation format (debugging)
//   [--speakers N | --min-speakers N --max-speakers N]
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
    var speakers: Int?
    var minSpeakers: Int?
    var maxSpeakers: Int?
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
    func int(_ flag: String) -> Int {
        guard let n = Int(value(flag)), n > 0 else { fail("\(flag) needs a positive integer", .usage) }
        return n
    }
    while let arg = it.next() {
        switch arg {
        case "--models": options.models = URL(fileURLWithPath: value(arg), isDirectory: true)
        case "--raw": options.raw = URL(fileURLWithPath: value(arg))
        case "--audio": options.audio = URL(fileURLWithPath: value(arg))
        case "--speakers": options.speakers = int(arg)
        case "--min-speakers": options.minSpeakers = int(arg)
        case "--max-speakers": options.maxSpeakers = int(arg)
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

/// Same file layout FluidAudio downloads, read without its download path.
func loadModels(from directory: URL) throws -> OfflineDiarizerModels {
    let started = Date()
    let names = ModelNames.OfflineDiarizer.self
    let required = [names.segmentationFile, names.fbankFile, names.embeddingFile,
                    names.pldaRhoFile, names.pldaParameters]
    let missing = required.filter {
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
    guard missing.isEmpty else {
        fail("models missing in \(directory.path): \(missing.joined(separator: ", "))", .modelsMissing)
    }

    func model(_ file: String, _ units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return try MLModel(contentsOf: directory.appendingPathComponent(file), configuration: configuration)
    }

    // Mirrors OfflineDiarizerModels.load: FBank is fastest on CPU, the rest
    // may use GPU/ANE. On macOS 14 `.all` is also the routing reported not to
    // hit the BNNS crash.
    return OfflineDiarizerModels(
        segmentationModel: try model(names.segmentationFile, .all),
        fbankModel: try model(names.fbankFile, .cpuOnly),
        embeddingModel: try model(names.embeddingFile, .all),
        pldaRhoModel: try model(names.pldaRhoFile, .all),
        pldaPsi: try loadPLDAPsi(directory.appendingPathComponent(names.pldaParameters)),
        compilationDuration: Date().timeIntervalSince(started)
    )
}

/// `plda-parameters.json` → psi vector. FluidAudio's own reader is private.
func loadPLDAPsi(_ url: URL) throws -> [Double] {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    guard let tensors = root?["tensors"] as? [String: Any],
          let psi = tensors["psi"] as? [String: Any],
          let base64 = psi["data_base64"] as? String,
          let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          bytes.count >= MemoryLayout<Float>.size
    else { throw NSError(domain: "corvin-diarize", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "bad plda-parameters.json"]) }
    var floats = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
    _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
    return floats.map(Double.init)
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

var config = OfflineDiarizerConfig.default
if let n = options.speakers {
    config = config.withSpeakers(exactly: n)
} else if options.minSpeakers != nil || options.maxSpeakers != nil {
    config = config.withSpeakers(min: options.minSpeakers, max: options.maxSpeakers)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        let started = Date()
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: try loadModels(from: options.models!))

        let progress: @Sendable (Int, Int) -> Void = { done, total in
            emit(["progress": done, "total": total])
        }
        let result: DiarizationResult
        if let raw = options.raw {
            result = try await manager.process(audio: try readRawSamples(raw), progressCallback: progress)
        } else {
            result = try await manager.process(options.audio!, progressCallback: progress)
        }

        emit([
            "segments": result.segments.map {
                ["speaker": $0.speakerId,
                 "start": Double($0.startTimeSeconds),
                 "end": Double($0.endTimeSeconds)] as [String: Any]
            },
            "seconds": Date().timeIntervalSince(started),
        ])
    } catch {
        fail("diarization failed: \(error.localizedDescription)", .failed)
    }
}
semaphore.wait()
