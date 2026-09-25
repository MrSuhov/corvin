import XCTest
@testable import Corvin

@MainActor
final class DiarizationModelEntryTests: XCTestCase {

    private func entry(_ id: String, helperAPI: Int, minAppVersion: String? = nil,
                       path: String = "Model.mlmodelc/model.mil") -> [String: Any] {
        var e: [String: Any] = [
            "id": id, "revision": "abc", "helperAPI": helperAPI,
            "files": [["path": path, "url": "https://huggingface.co/x/y/resolve/abc/\(path)",
                       "sha256": String(repeating: "0", count: 64), "sizeBytes": 1]],
        ]
        if let minAppVersion { e["minAppVersion"] = minAppVersion }
        return e
    }

    private func manifest(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "models": [], "diarization": entries])
    }

    /// The published manifest keeps pyannote (1) for 1.5.x next to Nemotron (2).
    func testPicksEntryForBundledHelper() throws {
        let data = try manifest([entry("pyannote", helperAPI: 1), entry("nemotron", helperAPI: 2)])
        XCTAssertEqual(DiarizationModelStore.entry(fromManifest: data, appVersion: "1.6.0")?.id, "nemotron")
    }

    func testIgnoresEntryForOtherHelper() throws {
        let data = try manifest([entry("pyannote", helperAPI: 1)])
        XCTAssertNil(DiarizationModelStore.entry(fromManifest: data, appVersion: "1.6.0"))
    }

    func testIgnoresEntryNeedingNewerApp() throws {
        let data = try manifest([entry("nemotron", helperAPI: 2, minAppVersion: "9.0")])
        XCTAssertNil(DiarizationModelStore.entry(fromManifest: data, appVersion: "1.6.0"))
    }

    func testRejectsPathClimbingOut() throws {
        let data = try manifest([entry("evil", helperAPI: 2, path: "../x.bin")])
        XCTAssertNil(DiarizationModelStore.entry(fromManifest: data, appVersion: "1.6.0"))
    }

    func testBundledEntryMatchesHelper() {
        let bundled = DiarizationModelEntry.bundled
        XCTAssertEqual(bundled.helperAPI, DiarizationClient.helperAPI)
        XCTAssertTrue(bundled.hasSafePaths)
        XCTAssertEqual(bundled.roots, ["Nemotron3Diarizer_offline.mlmodelc", "learnable_sil_emb.bin"])
    }
}
