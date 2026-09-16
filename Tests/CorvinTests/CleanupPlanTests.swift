import XCTest
@testable import Corvin

/// Cleanup deletes files for good, so its rules are decided here rather than
/// discovered in the field.
final class CleanupPlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { now.addingTimeInterval(-60 * 24 * 3600) }
    private var recent: Date { now.addingTimeInterval(-3600) }

    private func variant(_ output: String, date: Date, isCall: Bool = false) -> TranscriptRegistry.Variant {
        TranscriptRegistry.Variant(outputPath: output, sourceSize: 1, sourceModified: date,
                                   dictionaryName: nil, date: date, modelID: nil, isCall: isCall)
    }

    private func record(_ source: String, date: Date, isCall: Bool = false,
                        plain: Bool = false) -> TranscriptRegistry.Record {
        TranscriptRegistry.Record(sourcePath: source,
                                  plain: plain ? variant(source + ".txt", date: date) : nil,
                                  roles: isCall || !plain ? variant(source + "_roles.txt", date: date, isCall: isCall) : nil,
                                  updatedAt: date)
    }

    /// Everything exists and was modified `modified` ago unless told otherwise.
    private func input(callAudio: CleanupPeriod = .never,
                       transcripts: CleanupPeriod = .never,
                       dictation: CleanupPeriod = .never,
                       records: [TranscriptRegistry.Record] = [],
                       calls: Set<String> = [],
                       directories: [URL] = [],
                       contents: [String: [URL]] = [:],
                       protected: Set<String> = [],
                       modified: @escaping (URL) -> Date?) -> CleanupPlan.Input {
        CleanupPlan.Input(now: now, callAudio: callAudio, transcripts: transcripts, dictation: dictation,
                          records: records, calls: calls, callDirectories: directories,
                          protected: protected,
                          contents: { contents[$0.path] ?? [] },
                          modified: modified)
    }

    func testNeverDeletesNothing() {
        let plan = CleanupPlan.make(input(records: [record("/calls/a.m4a", date: old, isCall: true)],
                                          calls: ["/calls/a.m4a"],
                                          modified: { _ in self.old }))

        XCTAssertTrue(plan.isEmpty)
    }

    func testOldCallAudioGoesAndRecentStays() {
        let plan = CleanupPlan.make(input(callAudio: .month,
                                          calls: ["/calls/old.m4a", "/calls/new.m4a"],
                                          modified: { $0.lastPathComponent == "old.m4a" ? self.old : self.recent }))

        XCTAssertEqual(plan.audio.map(\.lastPathComponent), ["old.m4a"])
    }

    func testAFileInTheQueueIsNeverDeleted() {
        let plan = CleanupPlan.make(input(callAudio: .month,
                                          calls: ["/calls/old.m4a"],
                                          protected: ["/calls/old.m4a"],
                                          modified: { _ in self.old }))

        XCTAssertTrue(plan.audio.isEmpty)
    }

    func testCallRecordedBeforeTheIndexIsStillCleanedUp() {
        let plan = CleanupPlan.make(input(callAudio: .month,
                                          records: [record("/calls/legacy.m4a", date: old, isCall: true)],
                                          modified: { _ in self.old }))

        XCTAssertEqual(plan.audio.map(\.lastPathComponent), ["legacy.m4a"])
    }

    func testImportedAudioIsLeftAlone() {
        // A file the user transcribed, not a call Corvin recorded.
        let plan = CleanupPlan.make(input(callAudio: .month,
                                          records: [record("/Users/me/podcast.mp3", date: old, plain: true)],
                                          modified: { _ in self.old }))

        XCTAssertTrue(plan.audio.isEmpty)
    }

    func testUntranscribedRecordingInTheCallsFolderIsFound() {
        let folder = URL(fileURLWithPath: "/calls", isDirectory: true)
        let plan = CleanupPlan.make(input(callAudio: .week,
                                          directories: [folder],
                                          contents: ["/calls": [folder.appendingPathComponent("stray.m4a"),
                                                                folder.appendingPathComponent("notes.txt")]],
                                          modified: { _ in self.old }))

        XCTAssertEqual(plan.audio.map(\.lastPathComponent), ["stray.m4a"])
    }

    func testOldTranscriptsGoByTheirOwnPeriod() {
        let plan = CleanupPlan.make(input(transcripts: .month,
                                          records: [record("/calls/a.m4a", date: old, isCall: true),
                                                    record("/calls/b.m4a", date: recent, isCall: true)],
                                          modified: { _ in self.old }))

        XCTAssertEqual(plan.transcripts.map(\.lastPathComponent), ["a.m4a_roles.txt"])
        XCTAssertTrue(plan.audio.isEmpty, "the audio period is separate")
    }

    func testTranscriptAlreadyGoneIsNotListed() {
        let plan = CleanupPlan.make(input(transcripts: .month,
                                          records: [record("/calls/a.m4a", date: old, isCall: true)],
                                          modified: { _ in nil }))

        XCTAssertTrue(plan.transcripts.isEmpty)
    }

    func testDictationCutoffIsJustADate() {
        let plan = CleanupPlan.make(input(dictation: .week, modified: { _ in self.old }))

        XCTAssertNotNil(plan.dictationCutoff)
        XCTAssertEqual(plan.dictationCutoff!.timeIntervalSince(now), -7 * 24 * 3600, accuracy: 3600)
        XCTAssertFalse(plan.isEmpty)
    }

    func testPeriodCutoffs() {
        XCTAssertNil(CleanupPeriod.never.cutoff(from: now))
        XCTAssertLessThan(CleanupPeriod.halfYear.cutoff(from: now)!, CleanupPeriod.month.cutoff(from: now)!)
        XCTAssertLessThan(CleanupPeriod.month.cutoff(from: now)!, CleanupPeriod.week.cutoff(from: now)!)
    }
}
