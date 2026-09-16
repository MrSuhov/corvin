import XCTest
@testable import Corvin

final class HistoryEntryTests: XCTestCase {

    private func record(_ path: String, updatedAt: Date, roles: TranscriptRegistry.Variant? = nil,
                        plain: TranscriptRegistry.Variant? = nil) -> TranscriptRegistry.Record {
        TranscriptRegistry.Record(sourcePath: path, plain: plain, roles: roles, updatedAt: updatedAt)
    }

    private func variant(_ output: String, isCall: Bool = false, modelID: String? = nil,
                         date: Date = Date()) -> TranscriptRegistry.Variant {
        TranscriptRegistry.Variant(outputPath: output, sourceSize: 1, sourceModified: date,
                                   dictionaryName: nil, date: date, modelID: modelID, isCall: isCall)
    }

    private func call(_ app: String, startedAt: Date, duration: TimeInterval? = nil) -> CallInfo {
        CallInfo(bundleID: "com.example.\(app)", appName: app, startedAt: startedAt, duration: duration)
    }

    func testCallWithoutTranscriptIsListed() {
        let entries = HistoryEntry.merge(records: [],
                                         calls: ["/calls/a.m4a": call("Telegram", startedAt: Date())])

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isCall)
        XCTAssertEqual(entries[0].appName, "Telegram")
        XCTAssertTrue(entries[0].variants.isEmpty)
    }

    func testImportedFileWithoutCallIsListed() {
        let entries = HistoryEntry.merge(records: [record("/files/talk.m4a", updatedAt: Date())], calls: [:])

        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isCall)
        XCTAssertNil(entries[0].appName)
        XCTAssertEqual(entries[0].fileName, "talk.m4a")
    }

    func testCallAndItsTranscriptAreOneRow() {
        let path = "/calls/a.m4a"
        let entries = HistoryEntry.merge(
            records: [record(path, updatedAt: Date(), roles: variant("/calls/a_roles.txt", isCall: true))],
            calls: [path: call("Zoom", startedAt: Date(timeIntervalSince1970: 100), duration: 65)]
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].appName, "Zoom")
        XCTAssertEqual(entries[0].duration, 65)
        XCTAssertEqual(entries[0].variants.map(\.mode), [.call])
    }

    func testNewestFirst() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let entries = HistoryEntry.merge(
            records: [record("/files/old.m4a", updatedAt: old)],
            calls: ["/calls/new.m4a": call("Telegram", startedAt: new)]
        )

        XCTAssertEqual(entries.map(\.fileName), ["new.m4a", "old.m4a"])
    }

    func testCallRecordedBeforeTheIndexIsStillACall() {
        let entries = HistoryEntry.merge(
            records: [record("/calls/legacy.m4a", updatedAt: Date(),
                             roles: variant("/calls/legacy_roles.txt", isCall: true))],
            calls: [:]
        )

        XCTAssertTrue(entries[0].isCall)
        XCTAssertNil(entries[0].appName)
    }

    func testBothTranscriptsAreListedInOrder() {
        let entries = HistoryEntry.merge(
            records: [record("/files/talk.m4a", updatedAt: Date(),
                             roles: variant("/files/talk_roles.txt"),
                             plain: variant("/files/talk.txt"))],
            calls: [:]
        )

        XCTAssertEqual(entries[0].variants.map(\.mode), [.plain, .roles])
    }

    func testDurationFormatting() {
        XCTAssertEqual(HistoryEntry.formatDuration(65), "1:05")
        XCTAssertEqual(HistoryEntry.formatDuration(3725), "1:02:05")
        XCTAssertEqual(HistoryEntry.formatDuration(-5), "0:00")
    }
}
