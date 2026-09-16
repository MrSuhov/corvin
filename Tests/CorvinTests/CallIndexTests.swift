import XCTest
@testable import Corvin

@MainActor
final class CallIndexTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("calls.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func audioFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    func testSurvivesRelaunch() throws {
        let audio = try audioFile("call.m4a")
        let info = CallInfo(bundleID: "ru.keepcoder.Telegram", appName: "Telegram",
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            duration: 1234, partCount: 5)

        CallIndex(file: file).record(info, for: audio)

        XCTAssertEqual(CallIndex(file: file).info(for: audio), info)
    }

    func testPathIsStandardizedBeforeLookup() throws {
        let audio = try audioFile("call.m4a")
        let index = CallIndex(file: file)
        index.record(CallInfo(bundleID: "a", appName: "A", startedAt: Date()), for: audio)

        let indirect = directory.appendingPathComponent("./call.m4a")
        XCTAssertNotNil(index.info(for: indirect))
    }

    func testOlderEntriesWithoutDurationStillDecode() throws {
        let audio = try audioFile("call.m4a")
        let json = """
        {"\(audio.path)":{"bundleID":"x","appName":"X","startedAt":0,"partCount":1,\
        "recoveredAfterCrash":false,"somethingNew":7}}
        """
        try Data(json.utf8).write(to: file)

        let info = CallIndex(file: file).info(for: audio)

        XCTAssertEqual(info?.appName, "X")
        XCTAssertNil(info?.duration)
    }

    func testUnreadableFileLeavesAnEmptyIndex() throws {
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(CallIndex(file: file).calls.isEmpty)
    }

    func testPruneForgetsOnlyVanishedAndUnreferencedCalls() throws {
        let present = try audioFile("present.m4a")
        let gone = directory.appendingPathComponent("gone.m4a")
        let referenced = directory.appendingPathComponent("referenced.m4a")
        let index = CallIndex(file: file)
        for url in [present, gone, referenced] {
            index.record(CallInfo(bundleID: "a", appName: "A", startedAt: Date()), for: url)
        }

        index.prune(keeping: [referenced.standardizedFileURL.path])

        XCTAssertNotNil(index.info(for: present))
        XCTAssertNotNil(index.info(for: referenced))
        XCTAssertNil(index.info(for: gone))
    }

    func testRemoveForgetsOneCall() throws {
        let audio = try audioFile("call.m4a")
        let index = CallIndex(file: file)
        index.record(CallInfo(bundleID: "a", appName: "A", startedAt: Date()), for: audio)

        index.remove(audio)

        XCTAssertTrue(index.calls.isEmpty)
        XCTAssertTrue(CallIndex(file: file).calls.isEmpty)
    }
}

final class CallSidecarTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSidecarRoundTrip() {
        let url = CallRecordingParts.sidecarURL(in: directory, base: "Call Telegram 2026-09-16 10-00")
        XCTAssertEqual(url.lastPathComponent, "Call Telegram 2026-09-16 10-00.call.json")
        let info = CallInfo(bundleID: "ru.keepcoder.Telegram", appName: "Telegram",
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000))

        info.write(to: url)

        XCTAssertEqual(CallInfo.read(url), info)
    }

    func testMissingSidecarReadsAsNothing() {
        XCTAssertNil(CallInfo.read(CallRecordingParts.sidecarURL(in: directory, base: "nope")))
    }

    func testSidecarIsNotMistakenForAPart() {
        let part = CallRecordingParts.url(in: directory, base: "call", index: 1)
        let sidecar = CallRecordingParts.sidecarURL(in: directory, base: "call")

        let groups = CallRecordingParts.group([part, sidecar])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].parts, [part])
    }

    func testRemoveSidecarOfParts() {
        let part = CallRecordingParts.url(in: directory, base: "call", index: 1)
        let sidecar = CallRecordingParts.sidecarURL(in: directory, base: "call")
        CallInfo(bundleID: "a", appName: "A", startedAt: Date()).write(to: sidecar)

        CallRecorder.removeSidecar(of: [part])

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }
}
