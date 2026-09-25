import Foundation
import CryptoKit

/// One installable version of the speaker-diarization models: a set of files
/// that is only usable complete.
///
/// Declared in the `diarization` section of models.json, next to the whisper
/// models, so the set can be updated without an app release. Old clients
/// ignore the section: JSONDecoder skips keys it does not know.
struct DiarizationModelEntry: Decodable, Equatable {
    struct File: Decodable, Equatable {
        /// Relative to the models directory, e.g. `Nemotron3Diarizer_offline.mlmodelc/model.mil`.
        let path: String
        let url: URL
        let sha256: String
        let sizeBytes: Int64
    }

    let id: String
    /// Hugging Face commit the URLs are pinned to. Informational.
    let revision: String
    let minAppVersion: String?
    /// Must equal `DiarizationClient.helperAPI` for the bundled helper to read it.
    let helperAPI: Int
    let files: [File]

    var sizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    /// First path components, e.g. `Nemotron3Diarizer_offline.mlmodelc`.
    var roots: [String] {
        Array(Set(files.compactMap { $0.path.split(separator: "/").first.map(String.init) })).sorted()
    }

    /// Identity of the whole set. Stored on install; a different value in the
    /// manifest means an update is available.
    var fingerprint: String {
        let lines = files.map { "\($0.path) \($0.sha256.lowercased())" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Paths come from the network: nothing absolute, nothing climbing out.
    var hasSafePaths: Bool {
        files.allSatisfy { file in
            !file.path.hasPrefix("/") && !file.path.isEmpty
                && !file.path.split(separator: "/").contains("..")
                && file.url.scheme == "https"
        }
    }
}

/// Downloads, verifies and updates the diarization models in
/// `~/Library/Application Support/Corvin/Models/diarization`, the directory
/// `corvin-diarize` reads.
///
/// Files land in a staging directory and are checked against their sha256
/// before the directory is swapped in, so the helper never sees half a set.
@MainActor
final class DiarizationModelStore: ObservableObject {

    @Published private(set) var isInstalled = false
    @Published private(set) var updateAvailable = false
    /// 0…1 while downloading, nil otherwise.
    @Published private(set) var progress: Double?
    @Published private(set) var error: LocalizedMessage?

    let directory: URL
    private let modelsDirectory: URL
    private var cancelRequested = false

    private struct InstalledMarker: Codable {
        let id: String
        let fingerprint: String
        /// Absent in markers written before helperAPI 2, which were all 1.
        let helperAPI: Int?
        /// Top-level names of the installed set; absent in the same old markers.
        let roots: [String]?
    }

    init(modelsDirectory: URL? = nil) {
        let base = modelsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Corvin/Models", isDirectory: true)
        self.modelsDirectory = base
        self.directory = base.appendingPathComponent("diarization", isDirectory: true)
        refresh()
    }

    var isDownloading: Bool { progress != nil }

    /// The entry this build should have installed: the newest usable one from
    /// the cached manifest (refreshed by `ModelManager.refreshCatalog`), else
    /// the compiled-in one.
    var currentEntry: DiarizationModelEntry {
        Self.entry(fromManifest: ModelCatalog.cachedManifestData(in: modelsDirectory),
                   appVersion: Self.appVersion) ?? .bundled
    }

    /// Re-reads what is on disk. Cheap; call when the settings pane appears.
    func refresh() {
        guard let marker = readMarker(), isReadable(marker) else {
            isInstalled = false
            updateAvailable = false
            return
        }
        isInstalled = true
        updateAvailable = marker.fingerprint != currentEntry.fingerprint
    }

    /// Downloads the current entry. Also how an update is applied.
    func install() async {
        guard !isDownloading else { return }
        let entry = currentEntry
        guard entry.hasSafePaths else {
            error = LocalizedMessage("diarization.models.error.invalid")
            return
        }

        cancelRequested = false
        error = nil
        progress = 0
        defer { progress = nil }

        let staging = modelsDirectory.appendingPathComponent("diarization.partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            let total = max(entry.sizeBytes, 1)
            var done: Int64 = 0
            for file in entry.files {
                if cancelRequested { throw CancellationError() }
                let downloaded = try await Self.download(file.url)
                defer { try? FileManager.default.removeItem(at: downloaded) }

                guard ModelCatalog.sha256(ofFileAt: downloaded)?.lowercased() == file.sha256.lowercased() else {
                    flog("DiarizationModelStore: checksum mismatch for \(file.path)")
                    throw DiarizationModelError.checksumMismatch
                }
                let target = staging.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: downloaded, to: target)

                done += file.sizeBytes
                progress = Double(done) / Double(total)
            }

            let marker = InstalledMarker(id: entry.id, fingerprint: entry.fingerprint,
                                         helperAPI: entry.helperAPI, roots: entry.roots)
            try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent(Self.markerName))

            if FileManager.default.fileExists(atPath: directory.path) {
                _ = try FileManager.default.replaceItemAt(directory, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: directory)
            }
            flog("DiarizationModelStore: installed \(entry.id) (\(entry.files.count) files, \(entry.sizeBytes) bytes)")
        } catch is CancellationError {
            flog("DiarizationModelStore: download cancelled")
        } catch DiarizationModelError.checksumMismatch {
            error = LocalizedMessage("diarization.models.error.checksum")
        } catch {
            flog("DiarizationModelStore: install failed: \(error)")
            self.error = LocalizedMessage("diarization.models.error.download", error.localizedDescription)
        }
        refresh()
    }

    func cancel() {
        cancelRequested = true
    }

    // MARK: - Manifest

    static func entry(fromManifest data: Data?, appVersion: String) -> DiarizationModelEntry? {
        struct Section: Decodable { let diarization: [DiarizationModelEntry]? }
        guard let data, let entries = (try? JSONDecoder().decode(Section.self, from: data))?.diarization
        else { return nil }
        return entries.last { entry in
            entry.helperAPI == DiarizationClient.helperAPI
                && entry.hasSafePaths
                && entry.minAppVersion.map { ModelCatalog.compareVersions(appVersion, $0) >= 0 } ?? true
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Disk

    private static let markerName = "installed.json"

    private func readMarker() -> InstalledMarker? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.markerName)) else { return nil }
        return try? JSONDecoder().decode(InstalledMarker.self, from: data)
    }

    /// Whether the bundled helper can run on the installed set. Checked
    /// against what the marker says was installed, not the current entry: an
    /// older set of the same layout stays usable while its update is pending.
    /// A set of another layout (pyannote under a Nemotron helper) does not, and
    /// shows as not installed, so the pane offers the download.
    private func isReadable(_ marker: InstalledMarker) -> Bool {
        guard (marker.helperAPI ?? 1) == DiarizationClient.helperAPI,
              let roots = marker.roots, !roots.isEmpty else { return false }
        return roots.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// `URLSession.download(from:)` is macOS 12+; this runs on 11.
    private static func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                // The system deletes `location` as soon as this handler returns.
                let kept = FileManager.default.temporaryDirectory
                    .appendingPathComponent("corvin-diarization-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }.resume()
        }
    }
}

private enum DiarizationModelError: Error {
    case checksumMismatch
}

// MARK: - Compiled-in entry

extension DiarizationModelEntry {
    /// Used when the manifest is unreachable or has no usable entry. Generated
    /// from the same revision `scripts/generate-models-manifest.py` publishes.
    static let bundled: DiarizationModelEntry = {
        let revision = "1b0b133f6f8820292010afd776d8f9fbc9fca17e"
        let base = "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/resolve/\(revision)/"
        // (local path, repo path, sha256, size): the helper reads one flat
        // directory, the repo keeps the preset under monolithic/v2.
        let bundle = "Nemotron3Diarizer_offline.mlmodelc"
        let files: [(String, String, String, Int64)] = [
            ("\(bundle)/analytics/coremldata.bin", "monolithic/v2/\(bundle)/analytics/coremldata.bin",
             "491594df92282a4f2cef65e96d236e210a5c4627063e37e822ec858aaaad416d", 243),
            ("\(bundle)/coremldata.bin", "monolithic/v2/\(bundle)/coremldata.bin",
             "8b790c919c65744648c17290a26d3371e0e55db655310e7f8445080757b0bf08", 758),
            ("\(bundle)/model.mil", "monolithic/v2/\(bundle)/model.mil",
             "ea5673d9e9ec785e7c8fb628acd82f9f86214c46b6584eaacdb6faddcb3f0277", 505274),
            ("\(bundle)/weights/weight.bin", "monolithic/v2/\(bundle)/weights/weight.bin",
             "bab76e5f190d0e4a4e174e7fcb1e9beea58c6b2be56e665e2cac8fba6d10f7f1", 198654080),
            ("learnable_sil_emb.bin", "learnable_sil_emb.bin",
             "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7", 2048),
        ]
        return DiarizationModelEntry(
            id: "nemotron3-offline-1b0b133",
            revision: revision,
            minAppVersion: nil,
            helperAPI: 2,
            files: files.map { File(path: $0.0, url: URL(string: base + $0.1)!, sha256: $0.2, sizeBytes: $0.3) }
        )
    }()
}
