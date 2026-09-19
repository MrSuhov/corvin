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

    private func job(_ path: String, queuedAt: Date, status: FileTranscriptionQueue.Status = .pending,
                     mode: TranscriptMode = .plain) -> FileTranscriptionQueue.Job {
        var job = FileTranscriptionQueue.Job(url: URL(fileURLWithPath: path), mode: mode)
        job.queuedAt = queuedAt
        job.status = status
        return job
    }

    func testFileOnlyInTheQueueIsListed() {
        let entries = HistoryEntry.merge(records: [], calls: [:],
                                         jobs: [job("/files/new.m4a", queuedAt: Date())])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fileName, "new.m4a")
        XCTAssertTrue(entries[0].isQueued)
        XCTAssertTrue(entries[0].variants.isEmpty)
    }

    func testJobAndTranscriptOfOneFileAreOneRow() {
        let path = "/files/talk.m4a"
        let entries = HistoryEntry.merge(
            records: [record(path, updatedAt: Date(timeIntervalSince1970: 100), plain: variant("/files/talk.txt"))],
            calls: [:],
            jobs: [job(path, queuedAt: Date(timeIntervalSince1970: 200), mode: .roles)]
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].variants.map(\.mode), [.plain])
        XCTAssertEqual(entries[0].job?.mode, .roles)
    }

    func testLatestJobForAFileWins() {
        let path = "/files/talk.m4a"
        let entries = HistoryEntry.merge(records: [], calls: [:], jobs: [
            job(path, queuedAt: Date(timeIntervalSince1970: 100), status: .failed),
            job(path, queuedAt: Date(timeIntervalSince1970: 200), status: .transcribing),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].job?.status, .transcribing)
    }

    func testJustAddedFileComesFirst() {
        let entries = HistoryEntry.merge(
            records: [record("/files/old.m4a", updatedAt: Date(timeIntervalSince1970: 1000))],
            calls: ["/calls/call.m4a": call("Zoom", startedAt: Date(timeIntervalSince1970: 2000))],
            jobs: [job("/files/new.m4a", queuedAt: Date(timeIntervalSince1970: 3000))]
        )

        XCTAssertEqual(entries.map(\.fileName), ["new.m4a", "call.m4a", "old.m4a"])
    }

    func testRequeuedCallKeepsItsCallTime() {
        let path = "/calls/call.m4a"
        let started = Date(timeIntervalSince1970: 100)
        let entries = HistoryEntry.merge(records: [], calls: [path: call("Zoom", startedAt: started)],
                                         jobs: [job(path, queuedAt: Date(timeIntervalSince1970: 900), mode: .call)])

        XCTAssertEqual(entries[0].date, started)
        XCTAssertTrue(entries[0].isCall)
    }

    func testFinishedJobIsNotQueued() {
        let entries = HistoryEntry.merge(records: [], calls: [:],
                                         jobs: [job("/files/a.m4a", queuedAt: Date(), status: .failed)])

        XCTAssertFalse(entries[0].isQueued)
    }

    func testRememberedModelIsUsedOnlyWhileDownloaded() {
        XCTAssertEqual(FileTranscriptionQueue.resolveModelID("small", downloaded: ["small", "base"]), "small")
        XCTAssertNil(FileTranscriptionQueue.resolveModelID("large", downloaded: ["small"]))
        XCTAssertNil(FileTranscriptionQueue.resolveModelID(nil, downloaded: ["small"]))
    }

    func testDurationFormatting() {
        XCTAssertEqual(HistoryEntry.formatDuration(65), "1:05")
        XCTAssertEqual(HistoryEntry.formatDuration(3725), "1:02:05")
        XCTAssertEqual(HistoryEntry.formatDuration(-5), "0:00")
    }
}
