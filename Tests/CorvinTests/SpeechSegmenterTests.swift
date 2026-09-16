import XCTest
@testable import Corvin

/// The segmenter decides the shape and the times of a call transcript, so its
/// thresholds are pinned here rather than discovered on a real call.
final class SpeechSegmenterTests: XCTestCase {

    private let frame = SpeechSegmenter.frameDuration

    /// A tone where speech is, digital silence elsewhere.
    private func pcm(_ seconds: TimeInterval,
                     _ bursts: [(start: TimeInterval, end: TimeInterval, amplitude: Float)]) -> Data {
        let rate = SpeechSegmenter.sampleRate
        var samples = [Int16](repeating: 0, count: Int(seconds * rate))
        for burst in bursts {
            let from = max(0, Int(burst.start * rate))
            let to = min(samples.count, Int(burst.end * rate))
            guard to > from else { continue }
            for index in from..<to {
                let phase = Float(index) / Float(rate) * 200 * 2 * .pi
                samples[index] = Int16(sin(phase) * burst.amplitude * 32000)
            }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Uniform noise at `amplitude`, with speech bursts on top of it.
    private func noisy(_ seconds: TimeInterval, noise: Float,
                       _ bursts: [(start: TimeInterval, end: TimeInterval, amplitude: Float)] = []) -> Data {
        let rate = SpeechSegmenter.sampleRate
        var generator = SystemRandomNumberGenerator()
        var samples = [Int16](repeating: 0, count: Int(seconds * rate))
        for index in samples.indices {
            samples[index] = Int16(Float.random(in: -noise...noise, using: &generator) * 32000)
        }
        for burst in bursts {
            let from = max(0, Int(burst.start * rate))
            let to = min(samples.count, Int(burst.end * rate))
            guard to > from else { continue }
            for index in from..<to {
                let phase = Float(index) / Float(rate) * 200 * 2 * .pi
                let value = sin(phase) * burst.amplitude + Float(samples[index]) / 32000
                samples[index] = Int16(max(-1, min(1, value)) * 32000)
            }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Spans

    func testFindsEveryBurstAndNothingInTheSilence() {
        let spans = SpeechSegmenter.spans(pcm(6, [(1, 2, 0.3), (4, 5, 0.3)]))

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 1, accuracy: frame)
        XCTAssertEqual(spans[0].end, 2, accuracy: frame)
        XCTAssertEqual(spans[1].start, 4, accuracy: frame)
        XCTAssertEqual(spans[1].end, 5, accuracy: frame)
    }

    func testBreathPauseStaysInsideOneSpan() {
        let spans = SpeechSegmenter.spans(pcm(4, [(1, 1.5, 0.3), (1.7, 2.2, 0.3)]))

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].start, 1, accuracy: frame)
        XCTAssertEqual(spans[0].end, 2.2, accuracy: frame)
    }

    func testPauseLongerThanTheHangoverSplits() {
        let spans = SpeechSegmenter.spans(pcm(4, [(1, 1.5, 0.3), (2.2, 2.7, 0.3)]))

        XCTAssertEqual(spans.count, 2)
    }

    /// The reason the threshold has a ceiling: with `noiseFloor * 3` alone the
    /// low percentile lands inside speech here, the threshold goes above it and
    /// the channel vanishes from the transcript without an error.
    func testChannelThatIsAlmostAllSpeechIsStillFound() {
        let spans = SpeechSegmenter.spans(pcm(10, [(0.1, 9.9, 0.3)]))

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].duration, 9.8, accuracy: 0.1)
    }

    func testQuietClickIsDropped() {
        let spans = SpeechSegmenter.spans(pcm(5, [(1, 1.1, 0.02)]))

        XCTAssertTrue(spans.isEmpty)
    }

    func testShortLoudWordIsKept() {
        let spans = SpeechSegmenter.spans(pcm(5, [(1, 1.2, 0.3)]))

        XCTAssertEqual(spans.count, 1)
    }

    /// Room tone, a fan, a tap handing over hiss instead of silence. Taking it
    /// for speech would send an hour of nothing to whisper and call the result
    /// one reply.
    func testChannelWithNoiseButNoSpeechHasNoSpans() {
        for noise: Float in [0.008, 0.02, 0.05] {
            XCTAssertTrue(SpeechSegmenter.spans(noisy(20, noise: noise)).isEmpty,
                          "noise at \(noise) was taken for speech")
        }
    }

    /// The noise floor has to raise the threshold, or a room that is merely
    /// audible swallows the pauses and the whole channel becomes one span.
    func testSpeechInANoisyRoomIsStillSeparatedFromTheNoise() {
        let audio = noisy(20, noise: 0.04, [(2, 5, 0.3), (12, 15, 0.3)])

        let spans = SpeechSegmenter.spans(audio)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 2, accuracy: 0.1)
        XCTAssertEqual(spans[1].end, 15, accuracy: 0.1)
    }

    func testQuietSpanOfMiddlingLengthIsDropped() {
        // 0.2 s — long enough to pass `minDuration`, so only loudness saves it.
        let spans = SpeechSegmenter.spans(pcm(5, [(1, 1.2, 0.008), (3, 4, 0.3)]))

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].start, 3, accuracy: 0.05)
    }

    func testDigitalSilenceHasNoSpans() {
        XCTAssertTrue(SpeechSegmenter.spans(pcm(5, [])).isEmpty)
        XCTAssertTrue(SpeechSegmenter.spans(Data()).isEmpty)
    }

    // MARK: - Compaction and the map back

    func testCompactionKeepsOnlySpeechAndMapsTimeBack() {
        let audio = pcm(20, [(1, 2, 0.3), (15, 16, 0.3)])
        let spans = SpeechSegmenter.spans(audio)
        let compacted = CompactedAudio.make(audio, spans: spans)

        // Two seconds of speech plus the margins and one separator, not 20.
        XCTAssertEqual(compacted.duration, 2 + 4 * SpeechSegmenter.padding + CompactedAudio.separator,
                       accuracy: 0.05)
        XCTAssertEqual(compacted.pcm.count / 2,
                       Int(compacted.duration * SpeechSegmenter.sampleRate), accuracy: 320)

        // The first sample of the second span's audio maps back to where that
        // audio came from, margin included.
        let secondSpanStarts = 1 + 2 * SpeechSegmenter.padding + CompactedAudio.separator
        XCTAssertEqual(compacted.original(secondSpanStarts, edge: .start),
                       15 - SpeechSegmenter.padding, accuracy: 0.05)
    }

    func testSeparatorClampsStartsForwardAndEndsBackward() {
        let audio = pcm(20, [(1, 2, 0.3), (15, 16, 0.3)])
        let compacted = CompactedAudio.make(audio, spans: SpeechSegmenter.spans(audio))
        // Halfway through the separator between the two spans.
        let inside = 1 + 2 * SpeechSegmenter.padding + CompactedAudio.separator / 2

        XCTAssertEqual(compacted.original(inside, edge: .start),
                       15 - SpeechSegmenter.padding, accuracy: 0.05)
        XCTAssertEqual(compacted.original(inside, edge: .end),
                       2 + SpeechSegmenter.padding, accuracy: 0.05)
    }

    /// Margins must not make neighbouring spans overlap: whisper would hear the
    /// same word twice and transcribe it twice.
    func testMarginsNeverCopyTheSameAudioTwice() {
        let audio = pcm(6, [(1, 1.5, 0.3), (1.7, 2.2, 0.3)])
        // 0.2 s apart — closer than two margins, so the margins have to share.
        let spans = [SpeechSpan(start: 1, end: 1.5), SpeechSpan(start: 1.7, end: 2.2)]
        let compacted = CompactedAudio.make(audio, spans: spans)

        let speech = compacted.duration - CompactedAudio.separator
        // 0.5 + 0.5 of speech, the 0.2 s between them counted once because the
        // boundary is its midpoint, and one full margin at each outer end.
        XCTAssertEqual(speech, 1 + 0.2 + 2 * SpeechSegmenter.padding, accuracy: 0.05)
    }

    func testWordsComeBackOnTheRecordingsTimeline() {
        let audio = pcm(20, [(1, 2, 0.3), (15, 16, 0.3)])
        let compacted = CompactedAudio.make(audio, spans: SpeechSegmenter.spans(audio))
        let secondSpanStarts = 1 + 2 * SpeechSegmenter.padding + CompactedAudio.separator

        let placed = compacted.place([TimedWord(text: "раз", start: 0.2, end: 0.6),
                                      TimedWord(text: "два", start: secondSpanStarts + 0.2,
                                                end: secondSpanStarts + 0.6)])

        XCTAssertEqual(placed[0].start, 1 - SpeechSegmenter.padding + 0.2, accuracy: 0.05)
        XCTAssertEqual(placed[1].start, 15 - SpeechSegmenter.padding + 0.2, accuracy: 0.05)
        XCTAssertTrue(placed[1].end >= placed[1].start)
    }

    func testEmptySpansCompactToNothing() {
        let compacted = CompactedAudio.make(pcm(5, []), spans: [])

        XCTAssertTrue(compacted.isEmpty)
        XCTAssertTrue(compacted.pcm.isEmpty)
        XCTAssertEqual(compacted.duration, 0)
    }
}

/// A look at the segmenter's output on a real recording, for calibrating the
/// thresholds without spending minutes on whisper. Skipped unless pointed at a
/// file:
///
///     CORVIN_CALL_FILE="$HOME/Documents/Corvin/Calls/<name>.m4a" swift test \
///         --filter SpeechSegmenterFieldCheck 2>&1 | grep -A100 "field check"
final class SpeechSegmenterFieldCheck: XCTestCase {

    func testPrintsTheSpansOfARealCall() throws {
        guard let path = ProcessInfo.processInfo.environment["CORVIN_CALL_FILE"] else {
            throw XCTSkip("set CORVIN_CALL_FILE to a call recording")
        }
        let channels = try AudioFileDecoder.decodeChannels(url: URL(fileURLWithPath: path))
        print("field check: \(path)")

        for (name, pcm) in [("me", channels.left), ("other", channels.right)] {
            let spans = SpeechSegmenter.spans(pcm)
            let compacted = CompactedAudio.make(pcm, spans: spans)
            let total = Double(pcm.count / 2) / SpeechSegmenter.sampleRate
            print(String(format: "field check %@: %.1fs → %.1fs of speech in %d span(s)",
                         name, total, compacted.duration, spans.count))
            for span in spans {
                print(String(format: "field check %@   %6.2f – %6.2f  (%.2fs)",
                             name, span.start, span.end, span.duration))
            }
        }

        // The real grouping, with one stand-in word per span: whisper is not
        // needed to see whether the call comes out as a dialogue.
        func channel(_ pcm: Data) -> CallTranscriptBuilder.Channel {
            let spans = SpeechSegmenter.spans(pcm)
            return CallTranscriptBuilder.Channel(
                spans: spans,
                words: spans.map { TimedWord(text: "•", start: $0.start, end: $0.end) })
        }
        for turn in CallTranscriptBuilder.turns(me: channel(channels.left),
                                                other: channel(channels.right)) {
            print("field check turn [\(RolesFormatter.timestamp(turn.start))] "
                  + "\(turn.speaker == CallTranscriptBuilder.me ? "me   " : "other") \(turn.text)")
        }
    }
}

final class SoundEventTests: XCTestCase {

    func testDescribedSoundsAreRecognised() {
        XCTAssertTrue(TranscriptionEngine.isSoundEvent(" [Аплодисменты]"))
        XCTAssertTrue(TranscriptionEngine.isSoundEvent("(phone ringing)"))
        XCTAssertTrue(TranscriptionEngine.isSoundEvent(" ДИНАМИЧНАЯ МУЗЫКА"))
    }

    func testSpeechIsNot() {
        XCTAssertFalse(TranscriptionEngine.isSoundEvent(" Алло, слышно меня?"))
        XCTAssertFalse(TranscriptionEngine.isSoundEvent("ОК"), "an abbreviation is too short to judge")
        XCTAssertFalse(TranscriptionEngine.isSoundEvent(" Приедем в ООО «Ромашка»."))
        XCTAssertFalse(TranscriptionEngine.isSoundEvent(""))
    }
}
