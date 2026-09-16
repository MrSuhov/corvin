import XCTest
@testable import Corvin

/// Words 0.4 s apart, each 0.3 s long.
private func words(_ text: String, from start: TimeInterval) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { index, word in
        let begin = start + Double(index) * 0.4
        return TimedWord(text: String(word), start: begin, end: begin + 0.3)
    }
}

final class EchoFilterTests: XCTestCase {

    func testDropsPhraseHeardOnTheOtherChannel() {
        let other = words("Привет, как дела?", from: 1.0)
        let me = words("привет как дела", from: 1.3) + words("Нормально, спасибо.", from: 5.0)

        let kept = EchoFilter.filter(me: me, other: other)

        XCTAssertEqual(kept.map(\.text), ["Нормально,", "спасибо."])
    }

    func testKeepsOwnReplyOverlappingTheOtherSide() {
        let other = words("Ты придёшь завтра на встречу?", from: 1.0)
        let me = words("Да, конечно приду.", from: 2.0)

        XCTAssertEqual(EchoFilter.filter(me: me, other: other), me)
    }

    func testSameWordsFarApartAreNotEcho() {
        let other = words("хорошо договорились", from: 1.0)
        let me = words("хорошо договорились", from: 20.0)

        XCTAssertEqual(EchoFilter.filter(me: me, other: other), me)
    }

    func testNothingOnTheOtherChannelKeepsEverything() {
        let me = words("Алло, меня слышно?", from: 0)
        XCTAssertEqual(EchoFilter.filter(me: me, other: []), me)
    }
}

final class CallTranscriptBuilderTests: XCTestCase {

    func testInterleavesChannelsByTime() {
        let me = words("Алло.", from: 0) + words("Да, слушаю.", from: 4)
        let other = words("Привет, это Иван.", from: 1.5)

        let turns = CallTranscriptBuilder.build(me: me, other: other, otherSegments: [])

        XCTAssertEqual(turns.map(\.speaker), [CallTranscriptBuilder.me, 2, CallTranscriptBuilder.me])
        XCTAssertEqual(turns.map(\.text), ["Алло.", "Привет, это Иван.", "Да, слушаю."])
    }

    func testPauseAloneDoesNotSplitAReply() {
        let me = words("Раз.", from: 0) + words("Два.", from: 5)
        let other = words("Понял.", from: 10)

        let turns = CallTranscriptBuilder.build(me: me, other: other, otherSegments: [])

        XCTAssertEqual(turns.map(\.text), ["Раз. Два.", "Понял."])
    }

    func testOnlyOneSideSpoke() {
        let other = words("Это автоответчик, оставьте сообщение.", from: 0)

        let turns = CallTranscriptBuilder.build(me: [], other: other, otherSegments: [])

        XCTAssertEqual(turns.map(\.speaker), [2])
    }

    func testGroupCallNumbersTheOtherVoicesAfterMe() {
        let other = words("Добрый день, я Анна, отвечаю за продажи.", from: 0)
            + words("А я Борис, занимаюсь поддержкой клиентов.", from: 5)
        let segments = [SpeakerSegment(speaker: "S1", start: 0, end: 3.5),
                        SpeakerSegment(speaker: "S2", start: 4.5, end: 8)]

        let turns = CallTranscriptBuilder.build(me: [], other: other, otherSegments: segments)

        XCTAssertEqual(turns.map(\.speaker), [2, 3])
    }

    func testNothingSaid() {
        XCTAssertEqual(CallTranscriptBuilder.build(me: [], other: [], otherSegments: []), [])
    }
}

final class TimelineCursorTests: XCTestCase {

    func testContiguousChunksPassThrough() {
        var cursor = TimelineCursor()
        XCTAssertEqual(cursor.place([1, 2, 3], at: 0), [1, 2, 3])
        XCTAssertEqual(cursor.place([4, 5], at: 3), [4, 5])
        XCTAssertEqual(cursor.end, 5)
    }

    func testJitterWithinToleranceIsIgnored() {
        var cursor = TimelineCursor()
        _ = cursor.place([Float](repeating: 1, count: 1600), at: 0)
        let placed = cursor.place([Float](repeating: 1, count: 1600), at: 1600 + TimelineCursor.tolerance)
        XCTAssertEqual(placed.count, 1600)
        XCTAssertEqual(cursor.end, 3200)
    }

    func testGapIsFilledWithSilence() {
        var cursor = TimelineCursor()
        _ = cursor.place([Float](repeating: 1, count: 100), at: 0)
        let placed = cursor.place([1, 1], at: 1000)
        XCTAssertEqual(placed.count, 902)
        XCTAssertTrue(placed.prefix(900).allSatisfy { $0 == 0 })
        XCTAssertEqual(cursor.end, 1002)
    }

    func testOverlapIsDropped() {
        var cursor = TimelineCursor()
        _ = cursor.place([Float](repeating: 1, count: 1000), at: 0)
        let placed = cursor.place([Float](repeating: 2, count: 1000), at: 500)
        XCTAssertEqual(placed.count, 500)
        XCTAssertEqual(cursor.end, 1500)
    }

    func testPadOnlyMovesForward() {
        var cursor = TimelineCursor()
        _ = cursor.place([Float](repeating: 1, count: 1000), at: 0)
        XCTAssertTrue(cursor.pad(to: 500).isEmpty)
        XCTAssertEqual(cursor.pad(to: 1600).count, 600)
        XCTAssertEqual(cursor.end, 1600)
    }
}

final class AudioAppCatalogTests: XCTestCase {

    func testHelperProcessesBelongToTheirApp() {
        let chrome = CallApp(bundleID: "com.google.Chrome", name: "Google Chrome")
        XCTAssertTrue(AudioAppCatalog.belongs(bundleID: "com.google.Chrome", processName: nil, to: chrome))
        XCTAssertTrue(AudioAppCatalog.belongs(bundleID: "com.google.Chrome.helper", processName: nil, to: chrome))
        XCTAssertFalse(AudioAppCatalog.belongs(bundleID: "com.google.ChromeCanary", processName: nil, to: chrome))
    }

    func testWebKitProcessBelongsToTheAppItIsNamedAfter() {
        let safari = CallApp(bundleID: "com.apple.Safari", name: "Safari")
        XCTAssertTrue(AudioAppCatalog.belongs(bundleID: "com.apple.WebKit.GPU",
                                              processName: "Safari Graphics and Media", to: safari))
        XCTAssertFalse(AudioAppCatalog.belongs(bundleID: "com.apple.WebKit.GPU",
                                               processName: "Mail Graphics and Media", to: safari))
    }
}
