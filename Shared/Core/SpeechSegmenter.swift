import Foundation

/// A stretch of speech in one channel, in seconds from the start of the audio.
struct SpeechSpan: Equatable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { end - start }
}

/// Finds the speech in one channel of 16 kHz Int16 mono PCM.
///
/// Each channel of a call is mostly silence: the other side's turn is silence on
/// the microphone, and the other way round. Those silences carry the structure
/// of the conversation — who spoke when — and the recording's timeline is exact,
/// because `CallTimelineWriter` pads a quiet channel with silence instead of
/// closing the gap. So the audio is where a call transcript's times come from,
/// not whisper's token timestamps, which drift by whole seconds.
enum SpeechSegmenter {

    static let sampleRate = 16000.0
    /// 20 ms.
    static let frameSamples = 320
    /// Nothing below this is speech, whatever the noise floor says. Comparable
    /// to the peak threshold in `AudioFileDecoder.isAudible`.
    static let absoluteFloor: Float = 0.004
    /// A channel this loud throughout is taken for someone talking without a
    /// pause, and segmented even though its frames are all alike. Nothing in
    /// the energy of a signal separates uniform speech from uniform hiss, so
    /// the line sits where hiss stops being plausible — a channel this loud
    /// with no dynamics at all is a person, not a fan.
    static let speechLevel: Float = 0.08
    /// How much louder the loud frames must be than the quiet ones before the
    /// channel counts as a conversation at all.
    static let contrast: Float = 2.5
    /// A pause this short is inside a phrase, not between two of them.
    static let hangover: TimeInterval = 0.3
    /// Anything shorter is a click, a keystroke, a door.
    static let minDuration: TimeInterval = 0.12
    /// Up to this length a span has to be loud to be kept: "yes" and "mhm" are
    /// short, and dropping them is worse than mistiming them.
    static let quietDuration: TimeInterval = 0.25
    /// How far above the threshold such a short span must peak.
    static let loudEnough: Float = 4
    /// Margin around a span in the audio handed to whisper, so a word's onset
    /// is not clipped. It never moves a span's reported time.
    static let padding: TimeInterval = 0.15

    static var frameDuration: TimeInterval { Double(frameSamples) / sampleRate }

    static func spans(_ pcm: Data) -> [SpeechSpan] {
        let frames = levels(pcm)
        guard !frames.isEmpty, let threshold = threshold(frames.map(\.rms)) else { return [] }

        var spans: [SpeechSpan] = []
        var first = -1
        var last = -1
        var peak: Float = 0
        let gap = max(1, Int((hangover / frameDuration).rounded()))

        func close() {
            guard first >= 0 else { return }
            let span = SpeechSpan(start: Double(first) * frameDuration,
                                  end: Double(last + 1) * frameDuration)
            if keep(span, peak: peak, threshold: threshold) { spans.append(span) }
            first = -1
            peak = 0
        }

        for (index, frame) in frames.enumerated() where frame.rms >= threshold {
            // A gap shorter than the hangover keeps the run going.
            if first >= 0, index - last > gap { close() }
            if first < 0 { first = index }
            last = index
            peak = max(peak, frame.peak)
        }
        close()
        return spans
    }

    /// Two-sided on purpose, and `nil` when the channel holds no conversation.
    ///
    /// Three times the noise floor alone breaks down on a channel that is
    /// speech most of the time: a monologue puts the low percentile inside
    /// speech, the threshold lands above it, and the whole channel disappears
    /// from the transcript with no error anywhere. A quarter of the loud
    /// percentile alone breaks down the other way, letting room tone through as
    /// one span covering the entire call. The lower of the two is right in both
    /// cases, never below the absolute floor.
    ///
    /// A channel whose quiet and loud frames are alike is not a conversation —
    /// it is silence, or a fan, or a tap delivering hiss — unless it is loud
    /// throughout, which is what one person talking without pause looks like.
    static func threshold(_ rms: [Float]) -> Float? {
        let sorted = rms.sorted()
        let quiet = percentile(sorted, 0.10)
        let loud = percentile(sorted, 0.95)
        guard loud >= speechLevel || loud >= quiet * contrast else { return nil }
        return max(absoluteFloor, min(quiet * 3, loud * 0.25))
    }

    private static func keep(_ span: SpeechSpan, peak: Float, threshold: Float) -> Bool {
        if span.duration < minDuration { return false }
        if span.duration < quietDuration { return peak >= threshold * loudEnough }
        return true
    }

    private static func percentile(_ sorted: [Float], _ share: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * share).rounded())
        return sorted[index]
    }

    /// RMS and peak of every frame, both as a share of full scale.
    private static func levels(_ pcm: Data) -> [(rms: Float, peak: Float)] {
        pcm.withUnsafeBytes { raw -> [(rms: Float, peak: Float)] in
            let samples = raw.bindMemory(to: Int16.self)
            var result: [(rms: Float, peak: Float)] = []
            result.reserveCapacity(samples.count / frameSamples + 1)
            var start = 0
            while start + frameSamples <= samples.count {
                var sum: Float = 0
                var peak: Float = 0
                for index in start..<(start + frameSamples) {
                    let value = Float(samples[index]) / 32768
                    sum += value * value
                    peak = max(peak, abs(value))
                }
                result.append(((sum / Float(frameSamples)).squareRoot(), peak))
                start += frameSamples
            }
            return result
        }
    }
}

/// One channel's speech with the silence taken out, and the map back.
///
/// Whisper invents text on silence and spends its time on it either way, so it
/// is handed the speech alone. The separators are not there to absorb whisper's
/// timing drift — measured, they cannot — but to steer where the engine cuts its
/// 25-second chunks: `TranscriptionEngine.splitAtSilence` looks for the quietest
/// window in the last fifth of each chunk, and a separator wins that comparison
/// outright whenever one falls there, so a word is almost never split across a
/// chunk and drift does not accumulate past one.
struct CompactedAudio {

    /// Silence between two spans in the compacted stream.
    static let separator: TimeInterval = 0.4

    enum Edge {
        /// A word's start belongs to the span that follows a separator.
        case start
        /// A word's end belongs to the span before it.
        case end
    }

    let pcm: Data
    /// The spans this holds the audio of, in the original timeline. Never
    /// longer than what `pcm` actually carries.
    let spans: [SpeechSpan]

    /// Per span: where its audio sits in the compacted stream, where that same
    /// audio sits in the original, and how long it is. The padding is part of
    /// these, which is what keeps the mapping exact; `spans` stays unpadded, so
    /// a turn is stamped with the moment speech began.
    private let compactedStart: [TimeInterval]
    private let originalStart: [TimeInterval]
    private let length: [TimeInterval]

    var duration: TimeInterval {
        guard let last = compactedStart.indices.last else { return 0 }
        return compactedStart[last] + length[last]
    }

    var isEmpty: Bool { pcm.isEmpty }

    static func make(_ pcm: Data, spans: [SpeechSpan]) -> CompactedAudio {
        let rate = SpeechSegmenter.sampleRate
        let total = TimeInterval(pcm.count / 2) / rate
        let padding = SpeechSegmenter.padding

        var kept: [SpeechSpan] = []
        var compactedStart: [TimeInterval] = []
        var originalStart: [TimeInterval] = []
        var length: [TimeInterval] = []
        var audio = Data()
        audio.reserveCapacity(spans.reduce(0) { $0 + Int(($1.duration + 2 * padding + separator) * rate) * 2 })
        let silence = Data(count: Int(separator * rate) * 2)

        for (index, span) in spans.enumerated() {
            // The margin never crosses into a neighbour: a shared gap is split
            // down the middle, so no sample is copied twice and whisper cannot
            // hear a word twice.
            let previousEnd = index > 0 ? spans[index - 1].end : 0
            let nextStart = index + 1 < spans.count ? spans[index + 1].start : total
            let from = max(0, max(span.start - padding, (previousEnd + span.start) / 2))
            let to = min(total, min(span.end + padding, (span.end + nextStart) / 2))
            guard to > from else { continue }

            if !audio.isEmpty { audio += silence }
            kept.append(span)
            compactedStart.append(TimeInterval(audio.count / 2) / rate)
            originalStart.append(from)
            length.append(to - from)

            let lower = min(pcm.count, Int(from * rate) * 2)
            let upper = min(pcm.count, Int(to * rate) * 2)
            if upper > lower { audio += pcm[lower..<upper] }
        }

        return CompactedAudio(pcm: audio, spans: kept, compactedStart: compactedStart,
                              originalStart: originalStart, length: length)
    }

    /// The span a moment of the compacted stream belongs to.
    func index(at compacted: TimeInterval, edge: Edge) -> Int? {
        guard !compactedStart.isEmpty else { return nil }
        for index in compactedStart.indices {
            if compacted < compactedStart[index] {
                // Inside a separator, or before the first span.
                return edge == .start ? index : max(0, index - 1)
            }
            if compacted <= compactedStart[index] + length[index] { return index }
        }
        return compactedStart.count - 1
    }

    /// Compacted time → the original recording's time.
    func original(_ compacted: TimeInterval, edge: Edge) -> TimeInterval {
        guard let index = index(at: compacted, edge: edge) else { return compacted }
        let offset = compacted - compactedStart[index]
        return originalStart[index] + min(max(0, offset), length[index])
    }

    /// Word times from the compacted stream, back on the recording's timeline.
    func place(_ words: [TimedWord]) -> [TimedWord] {
        words.map {
            let start = original($0.start, edge: .start)
            return TimedWord(text: $0.text, start: start,
                             end: max(start, original($0.end, edge: .end)))
        }
    }
}
