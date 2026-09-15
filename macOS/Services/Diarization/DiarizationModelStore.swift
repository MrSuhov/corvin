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
        /// Relative to the models directory, e.g. `Segmentation.mlmodelc/model.mil`.
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
        guard let marker = readMarker(), requiredModelsExist() else {
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

            let marker = InstalledMarker(id: entry.id, fingerprint: entry.fingerprint)
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

    /// What corvin-diarize loads. Checked by name rather than against the
    /// current entry's file list: an installed older set stays usable while
    /// its update is pending, even if the new entry lists different files.
    private func requiredModelsExist() -> Bool {
        ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
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
        let revision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
        let base = "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/\(revision)/"
        let files: [(String, String, Int64)] = [
            ("Segmentation.mlmodelc/analytics/coremldata.bin", "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb", 243),
            ("Segmentation.mlmodelc/coremldata.bin", "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc", 812),
            ("Segmentation.mlmodelc/metadata.json", "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124", 3410),
            ("Segmentation.mlmodelc/model.mil", "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f", 43063),
            ("Segmentation.mlmodelc/weights/weight.bin", "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2", 5959360),
            ("FBank.mlmodelc/analytics/coremldata.bin", "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a", 243),
            ("FBank.mlmodelc/coremldata.bin", "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759", 853),
            ("FBank.mlmodelc/metadata.json", "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a", 3409),
            ("FBank.mlmodelc/model.mil", "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed", 15667),
            ("FBank.mlmodelc/weights/weight.bin", "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36", 1776896),
            ("Embedding.mlmodelc/analytics/coremldata.bin", "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682", 243),
            ("Embedding.mlmodelc/coremldata.bin", "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004", 704),
            ("Embedding.mlmodelc/metadata.json", "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5", 2818),
            ("Embedding.mlmodelc/model.mil", "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3", 78432),
            ("Embedding.mlmodelc/weights/weight.bin", "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b", 13412288),
            ("PldaRho.mlmodelc/analytics/coremldata.bin", "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7", 243),
            ("PldaRho.mlmodelc/coremldata.bin", "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418", 763),
            ("PldaRho.mlmodelc/metadata.json", "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945", 2749),
            ("PldaRho.mlmodelc/model.mil", "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041", 7613),
            ("PldaRho.mlmodelc/weights/weight.bin", "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36", 200192),
            ("plda-parameters.json", "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f", 89416),
        ]
        return DiarizationModelEntry(
            id: "fluid-offline-1ed7a66",
            revision: revision,
            minAppVersion: nil,
            helperAPI: 1,
            files: files.map { File(path: $0.0, url: URL(string: base + $0.0)!, sha256: $0.1, sizeBytes: $0.2) }
        )
    }()
}
