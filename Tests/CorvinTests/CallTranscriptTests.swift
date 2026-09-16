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

/// A span covering the words it is given, as the segmenter would have found it.
private func span(_ words: [TimedWord]) -> SpeechSpan {
    SpeechSpan(start: words[0].start, end: words[words.count - 1].end)
}

final class CallTranscriptBuilderTests: XCTestCase {

    private func channel(_ groups: [[TimedWord]],
                         speakers: [SpeakerSegment] = []) -> CallTranscriptBuilder.Channel {
        CallTranscriptBuilder.Channel(spans: groups.map(span), words: groups.flatMap { $0 },
                                      speakers: speakers)
    }

    func testInterleavesChannelsByTime() {
        let mine = channel([words("Алло.", from: 0), words("Да, слушаю.", from: 4)])
        let other = channel([words("Привет, это Иван.", from: 1.5)])

        let turns = CallTranscriptBuilder.turns(me: mine, other: other)

        XCTAssertEqual(turns.map(\.speaker), [CallTranscriptBuilder.me, 2, CallTranscriptBuilder.me])
        XCTAssertEqual(turns.map(\.text), ["Алло.", "Привет, это Иван.", "Да, слушаю."])
    }

    /// Every turn carries the moment its own speech began — the bug this
    /// replaced stamped a whole call with the time of its first word.
    func testEveryTurnIsStampedWithItsOwnStart() {
        let mine = channel([words("Алло.", from: 0.5), words("Да, слушаю.", from: 40)])
        let other = channel([words("Привет.", from: 20)])

        let turns = CallTranscriptBuilder.turns(me: mine, other: other)

        XCTAssertEqual(turns.map { RolesFormatter.timestamp($0.start) },
                       ["00:00:00", "00:00:20", "00:00:40"])
    }

    /// A monologue breathes. Without speech from the other side, a pause is not
    /// a new reply — which is the opposite of what the old builder did with the
    /// other side's channel, and the reason a whole call came out as one block.
    func testBreathingPauseDoesNotStartANewReply() {
        let mine = channel([words("Раз.", from: 0), words("Два.", from: 2)])
        let other = channel([words("Понял.", from: 10)])

        let turns = CallTranscriptBuilder.turns(me: mine, other: other)

        XCTAssertEqual(turns.map(\.text), ["Раз. Два.", "Понял."])
    }

    func testTheOtherSideSpeakingEndsMyReplyEvenAfterAShortPause() {
        let mine = channel([words("Раз.", from: 0), words("Два.", from: 2)])
        let other = channel([words("Ага.", from: 1)])

        let turns = CallTranscriptBuilder.turns(me: mine, other: other)

        XCTAssertEqual(turns.map(\.speaker), [CallTranscriptBuilder.me, 2, CallTranscriptBuilder.me])
        XCTAssertEqual(turns.map(\.text), ["Раз.", "Ага.", "Два."])
    }

    /// What `EchoFilter` took out leaves a span with nothing in it.
    func testSpanWithoutWordsIsDropped() {
        let mine = CallTranscriptBuilder.Channel(
            spans: [SpeechSpan(start: 0, end: 1), SpeechSpan(start: 30, end: 31)],
            words: words("Только это.", from: 30))
        let turns = CallTranscriptBuilder.turns(me: mine, other: channel([]))

        XCTAssertEqual(turns.map(\.text), ["Только это."])
        XCTAssertEqual(turns.map { RolesFormatter.timestamp($0.start) }, ["00:00:30"])
    }

    func testOnlyOneSideSpoke() {
        let other = channel([words("Это автоответчик, оставьте сообщение.", from: 0)])

        let turns = CallTranscriptBuilder.turns(me: channel([]), other: other)

        XCTAssertEqual(turns.map(\.speaker), [2])
    }

    func testGroupCallNumbersTheOtherVoicesAfterMe() {
        let other = channel([words("Добрый день, я Анна, отвечаю за продажи.", from: 0),
                             words("А я Борис, занимаюсь поддержкой клиентов.", from: 5)],
                            speakers: [SpeakerSegment(speaker: "S1", start: 0, end: 3.5),
                                       SpeakerSegment(speaker: "S2", start: 4.5, end: 10)])

        let turns = CallTranscriptBuilder.turns(me: channel([]), other: other)

        XCTAssertEqual(turns.map(\.speaker), [2, 3])
    }

    /// A voice change splits a reply even when the pause is short enough to
    /// join, because it is no longer the same person talking.
    func testVoiceChangeSplitsAReply() {
        let first = words("Мы согласны.", from: 0)
        let second = words("Я тоже.", from: 1.5)
        let other = channel([first, second],
                            speakers: [SpeakerSegment(speaker: "S1", start: 0, end: 1.2),
                                       SpeakerSegment(speaker: "S2", start: 1.4, end: 4)])

        let turns = CallTranscriptBuilder.turns(me: channel([]), other: other)

        XCTAssertEqual(turns.map(\.speaker), [2, 3])
    }

    /// A monologue built of many short stretches: one reply, because every
    /// pause is under `joinPause` and the other side says nothing.
    private func monologue(spans count: Int, of length: TimeInterval,
                           apart gap: TimeInterval) -> CallTranscriptBuilder.Channel {
        var spans: [SpeechSpan] = []
        var said: [TimedWord] = []
        for index in 0..<count {
            let start = Double(index) * (length + gap)
            spans.append(SpeechSpan(start: start, end: start + length))
            said += words("раз два три четыре пять", from: start)
        }
        return CallTranscriptBuilder.Channel(spans: spans, words: said)
    }

    /// A long reply is cut at a silence between its spans, so the next turn
    /// gets a time the audio vouches for, and the cut lands near the 40 s mark
    /// rather than peeling one span at a time.
    func testLongReplyIsCutNearTheMarkAtASilence() {
        let mine = monologue(spans: 12, of: 5, apart: 1)
        XCTAssertEqual(mine.spans.last?.end, 71, "one reply of 71 s")

        let turns = CallTranscriptBuilder.turns(me: mine, other: CallTranscriptBuilder.Channel(spans: [], words: []))

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(turns[1].start, 36, accuracy: 0.01)
    }

    /// Nothing but one unbroken stretch of speech: the cut has to happen inside
    /// it, or the whole monologue comes back as a single block stamped
    /// [00:00:00] — the bug this design exists to remove.
    func testOneLongSpanIsStillCut() {
        let said = (0..<150).map { index in
            TimedWord(text: index % 10 == 9 ? "стоп." : "слово",
                      start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.3)
        }
        let mine = CallTranscriptBuilder.Channel(spans: [SpeechSpan(start: 0, end: 60)], words: said)

        let turns = CallTranscriptBuilder.turns(me: mine, other: CallTranscriptBuilder.Channel(spans: [], words: []))

        XCTAssertGreaterThan(turns.count, 1)
        XCTAssertTrue(turns.dropFirst().allSatisfy { $0.start > 0 })
        XCTAssertEqual(turns.map(\.text).joined(separator: " ").split(separator: " ").count, said.count,
                       "a cut must not lose a word")
    }

    /// The tail is stamped where it was cut, not where its next span begins:
    /// the words in between are its own.
    func testTailOfACutReplyIsStampedAtTheCut() {
        var said = (0..<125).map {
            TimedWord(text: $0 % 25 == 24 ? "точка." : "слово",
                      start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3)
        }
        said += words("И ещё одно.", from: 51)
        let mine = CallTranscriptBuilder.Channel(
            spans: [SpeechSpan(start: 0, end: 50), SpeechSpan(start: 51, end: 53)], words: said)

        let turns = CallTranscriptBuilder.turns(me: mine, other: CallTranscriptBuilder.Channel(spans: [], words: []))

        XCTAssertGreaterThan(turns.count, 1)
        XCTAssertLessThan(turns[1].start, 50, "the tail starts inside the first span, not at the next one")
        XCTAssertTrue(turns[1].text.contains("слово"), turns[1].text)
    }

    /// A short "mhm" the diarizer did not cover belongs to whoever is nearest,
    /// not to a new person: numbering it separately printed one human as two.
    func testSpanTheDiarizerMissedDoesNotBecomeANewVoice() {
        let other = channel([words("Да, мы согласны.", from: 0),
                             words("Ага.", from: 5),
                             words("Тогда до встречи.", from: 10)],
                            speakers: [SpeakerSegment(speaker: "S1", start: 0, end: 2),
                                       SpeakerSegment(speaker: "S1", start: 9.5, end: 12)])

        let turns = CallTranscriptBuilder.turns(me: channel([]), other: other)

        XCTAssertEqual(Set(turns.map(\.speaker)), [2])
    }

    func testNothingSaid() {
        XCTAssertEqual(CallTranscriptBuilder.turns(me: channel([]), other: channel([])), [])
    }

    // MARK: - The header

    private let call = CallInfo(bundleID: "ru.keepcoder.Telegram", appName: "Telegram",
                                startedAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 391)

    private var oneTurn: [SpeakerTurn] {
        CallTranscriptBuilder.turns(me: channel([words("Алло.", from: 0)]), other: channel([]))
    }

    func testHeaderIsPrependedWithoutTouchingTheScript() {
        let script = CallTranscriptBuilder.format(oneTurn)
        let text = CallTranscriptBuilder.format(oneTurn, call: call)

        XCTAssertTrue(text.hasSuffix(script), text)
        // Three lines of header and the blank line after them.
        XCTAssertEqual(text.components(separatedBy: "\n").count,
                       script.components(separatedBy: "\n").count + 4)
    }

    /// The test bundle carries no string catalogue, so a key resolves to
    /// itself — which is all this needs to see which lines the header has.
    func testHeaderLeavesOutALengthNobodyMeasured() {
        let unmeasured = CallInfo(bundleID: call.bundleID, appName: call.appName,
                                  startedAt: call.startedAt, duration: nil)

        XCTAssertTrue(CallTranscriptBuilder.format(oneTurn, call: call)
            .contains("call.transcript.duration"))
        XCTAssertFalse(CallTranscriptBuilder.format(oneTurn, call: unmeasured)
            .contains("call.transcript.duration"))
    }

    func testNoHeaderForACallNobodyRemembers() {
        XCTAssertEqual(CallTranscriptBuilder.format(oneTurn, call: nil),
                       CallTranscriptBuilder.format(oneTurn))
        XCTAssertTrue(CallTranscriptBuilder.format(oneTurn).hasPrefix("["))
    }

    func testNoHeaderWithoutAScript() {
        XCTAssertTrue(CallTranscriptBuilder.format([], call: call).isEmpty)
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
