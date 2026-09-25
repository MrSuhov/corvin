import XCTest
@testable import Corvin

/// Non-whisper models in the catalogue: which build sees them, where they
/// live on disk, and how their words are timed.
final class ModelFamilyTests: XCTestCase {

    private func entry(_ id: String, family: String? = nil, languages: [String]? = nil,
                       minAppVersion: String? = nil) -> [String: Any] {
        var e: [String: Any] = [
            "id": id, "name": id, "size": "1 MB", "ramRequired": "~1 MB", "quality": "q", "speed": "s",
            "downloadURL": "https://huggingface.co/x/y/resolve/abc/\(id).bin",
            "sha256": String(repeating: "0", count: 64), "recommended": false, "tier": "free",
        ]
        if let family { e["family"] = family }
        if let languages { e["languages"] = languages }
        if let minAppVersion { e["minAppVersion"] = minAppVersion }
        return e
    }

    private func decode(_ entries: [[String: Any]], appVersion: String = "1.5.4") throws -> [WhisperModel]? {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "models": entries])
        return ModelCatalog.decode(data, appVersion: appVersion)
    }

    func testEntryWithoutFamilyIsWhisper() throws {
        let model = try XCTUnwrap(try decode([entry("small")])?.first)
        XCTAssertEqual(model.family, .whisper)
        XCTAssertNil(model.languages)
        XCTAssertTrue(model.supportsPrompt)
        XCTAssertTrue(model.supportsStreaming)
    }

    func testGigaAMEntryCarriesFamilyAndLanguage() throws {
        let model = try XCTUnwrap(try decode([entry("gigaam-v3-q8", family: "gigaam", languages: ["ru"])])?.first)
        XCTAssertEqual(model.family, .gigaam)
        XCTAssertEqual(model.languages, ["ru"])
        XCTAssertFalse(model.supportsPrompt)
        XCTAssertFalse(model.supportsStreaming)
    }

    /// An older build would take a GGUF for a whisper model; the manifest
    /// hides it with minAppVersion.
    func testGigaAMHiddenFromOlderApp() throws {
        let models = try decode([entry("small"), entry("gigaam-v3-q8", family: "gigaam", minAppVersion: "1.5.4")],
                                appVersion: "1.5.3")
        XCTAssertEqual(models?.map(\.id), ["small"])
    }

    func testUnknownFamilyIsDropped() throws {
        let models = try decode([entry("small"), entry("future", family: "parakeet")])
        XCTAssertEqual(models?.map(\.id), ["small"])
    }

    func testFileNamesByFamily() {
        let whisper = WhisperModel.all.first { $0.id == "small" }
        XCTAssertEqual(whisper?.fileName, "ggml-small.bin")
        let gigaam = WhisperModel.all.first { $0.family == .gigaam }
        XCTAssertEqual(gigaam?.fileName, "\(gigaam?.id ?? "").gguf")
    }

    /// Token rows as GigaAM returns them for "Такой чек на $75 000."
    func testWordsAssembledFromTokens() {
        let mark = TranscribeCppWords.wordMark
        let tokens: [(text: String, startMs: Int64, endMs: Int64)] = [
            ("\(mark)Так", 120, 160), ("ой", 240, 280),
            (mark, 320, 360), ("че", 400, 440), ("к", 520, 560),
            ("\(mark)на", 880, 920),
            (mark, 1040, 1080), ("$", 1120, 1160), ("7", 1200, 1240), ("5", 1640, 1680),
            ("\(mark)000", 1920, 1960), (".", 2800, 2840),
        ]
        let words = TranscribeCppWords.words(from: tokens)
        XCTAssertEqual(words.map(\.text), ["Такой", "чек", "на", "$75", "000."])
        XCTAssertEqual(words[1].start, 0.4, accuracy: 0.001)
        XCTAssertEqual(words[1].end, 0.56, accuracy: 0.001)
        XCTAssertEqual(words.last?.end ?? 0, 2.84, accuracy: 0.001)
    }
}
