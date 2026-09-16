import Foundation

/// A call's script, built from its two channels.
///
/// The channels already say who is who: the microphone is the user, the app's
/// audio is everyone else. Diarization only has to tell the other side's voices
/// apart in a group call, and it runs on that channel alone.
///
/// What decides the *shape* is the audio, not the words. Each side's speech was
/// found by `SpeechSegmenter`, whose times are exact — the recording pads a
/// quiet channel with silence instead of closing the gap — so replies alternate
/// the way they did on the call, and each one is stamped with the moment it
/// began. Whisper's own token timestamps drift by seconds and are used only to
/// decide which reply a word belongs to.
///
/// Speaker numbers in the result: `me` (1) is the user; 2, 3… are the other
/// side in order of first appearance.
enum CallTranscriptBuilder {

    static let me = 1
    /// Two stretches of speech from one side this close together, with nothing
    /// from the other side in between, are one reply. A flat pause threshold
    /// cannot do this job: a monologue breathes every couple of seconds, and
    /// splitting on that alone would shred it into a column of "Me" blocks.
    static let joinPause: TimeInterval = 3
    /// A reply longer than this is broken up, so a long monologue still carries
    /// timestamps.
    static let maxTurn: TimeInterval = 40
    /// How far a reply boundary may move to land in a gap between words.
    static let snapWindow: TimeInterval = 2

    /// One side of the call.
    struct Channel {
        /// Speech found in the audio, in the recording's timeline.
        let spans: [SpeechSpan]
        /// Words from whisper, already placed back on that same timeline.
        let words: [TimedWord]
        /// Diarization of this side; empty means one voice.
        let speakers: [SpeakerSegment]

        init(spans: [SpeechSpan], words: [TimedWord], speakers: [SpeakerSegment] = []) {
            self.spans = spans
            self.words = words
            self.speakers = speakers
        }
    }

    /// A run of speech from one side that reads as a single reply.
    private struct Reply {
        var spans: [SpeechSpan]
        let isMine: Bool
        /// Diarization label; nil on the user's channel, which is one voice by
        /// definition, and on the other channel when diarization did not run.
        let voice: String?
        var words: [TimedWord] = []

        var start: TimeInterval { spans[0].start }
        var end: TimeInterval { spans[spans.count - 1].end }
    }

    static func turns(me mine: Channel, other: Channel) -> [SpeakerTurn] {
        var replies = group(mine, isMine: true, against: other.spans)
        replies += group(other, isMine: false, against: mine.spans)
        replies.sort { ($0.start, $0.isMine ? 0 : 1) < ($1.start, $1.isMine ? 0 : 1) }

        // Each channel's words are split among that channel's replies, which do
        // not overlap in time — so a word lands in exactly one of them, whatever
        // diarization later says about the voice.
        assign(mine.words, to: &replies, isMine: true)
        assign(other.words, to: &replies, isMine: false)

        // The other side's voices are numbered after the user, in the order
        // they first say something.
        var numbers: [String: Int] = [:]
        var turns: [SpeakerTurn] = []
        for reply in replies {
            // No words means nothing was said there after all: a noise the
            // segmenter kept, or the user's own echo that `EchoFilter` removed.
            guard !reply.words.isEmpty else { continue }
            var speaker = me
            if !reply.isMine {
                let voice = reply.voice ?? oneVoice
                if numbers[voice] == nil { numbers[voice] = numbers.count + me + 1 }
                speaker = numbers[voice]!
            }
            turns += split(reply, speaker: speaker)
        }
        return turns.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    /// The script with "Me" / "Other", or "Other 1", "Other 2" once the other
    /// side has more than one voice, under a header naming the call.
    static func format(_ turns: [SpeakerTurn], call: CallInfo? = nil) -> String {
        let others = Set(turns.map(\.speaker)).subtracting([me]).count
        let script = RolesFormatter.format(turns) { speaker in
            if speaker == me { return "roles.me".localized }
            return others > 1 ? "roles.otherNumbered".localized(with: speaker - 1) : "roles.other".localized
        }
        guard let call, !script.isEmpty else { return script }
        return header(call) + "\n" + script
    }

    /// Which app, when, how long. The file name cannot say it — it is localized
    /// — and the times inside the script are offsets from the start.
    private static func header(_ call: CallInfo) -> String {
        let date = DateFormatter()
        date.locale = LocalizedBundle.locale
        date.dateStyle = .long
        date.timeStyle = .medium

        var lines = ["call.transcript.app".localized(with: call.appName),
                     "call.transcript.startedAt".localized(with: date.string(from: call.startedAt))]
        if let duration = call.duration {
            lines.append("call.transcript.duration".localized(with: RolesFormatter.duration(duration)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Replies

    /// Stands in for a diarization label on a channel that was never diarized,
    /// so numbering has one code path.
    private static let oneVoice = "one"

    /// Spans become replies: a pause splits them when it is long, when the
    /// other side spoke into it, or when diarization says the voice changed.
    private static func group(_ channel: Channel, isMine: Bool, against otherSpans: [SpeechSpan]) -> [Reply] {
        var replies: [Reply] = []
        for span in channel.spans {
            let voice = isMine ? nil : self.voice(of: span, in: channel.speakers)
            if let last = replies.last, last.voice == voice,
               span.start - last.end < joinPause,
               !spoke(otherSpans, between: last.end, and: span.start) {
                replies[replies.count - 1].spans.append(span)
            } else {
                replies.append(Reply(spans: [span], isMine: isMine, voice: voice))
            }
        }
        return replies
    }

    /// The diarizer's label for a span, or nil on a channel it never saw.
    ///
    /// A span no segment covers — a short "mhm" the diarizer passed over —
    /// belongs to the nearest voice, never to a new one: a fresh label here
    /// would print one person as "Other 1" and "Other 2" through the whole
    /// call. `SpeakerTranscriptBuilder.speaker(for:in:)` settles it the same
    /// way.
    private static func voice(of span: SpeechSpan, in speakers: [SpeakerSegment]) -> String? {
        guard !speakers.isEmpty else { return nil }
        var best: SpeakerSegment?
        var bestOverlap = 0.0
        for segment in speakers {
            let overlap = min(span.end, segment.end) - max(span.start, segment.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = segment
            }
        }
        if let best { return best.speaker }

        let middle = (span.start + span.end) / 2
        func distance(_ segment: SpeakerSegment) -> TimeInterval {
            max(0, max(segment.start - middle, middle - segment.end))
        }
        return speakers.min { distance($0) < distance($1) }?.speaker
    }

    private static func spoke(_ spans: [SpeechSpan], between from: TimeInterval, and to: TimeInterval) -> Bool {
        spans.contains { $0.start < to && $0.end > from }
    }

    // MARK: - Words

    /// Words go to one channel's replies, in order. Whisper's times are off by
    /// as much as two seconds, so a boundary is nudged to the widest gap
    /// between words near it rather than trusted as it stands.
    private static func assign(_ words: [TimedWord], to replies: inout [Reply], isMine: Bool) {
        let indices = replies.indices.filter { replies[$0].isMine == isMine }
        guard !indices.isEmpty, !words.isEmpty else { return }

        var boundaries: [TimeInterval] = []
        for pair in zip(indices, indices.dropFirst()) {
            let raw = (replies[pair.0].end + replies[pair.1].start) / 2
            boundaries.append(snap(raw, to: words, after: boundaries.last))
        }

        var cursor = 0
        for (slot, index) in indices.enumerated() {
            let upper = slot < boundaries.count ? boundaries[slot] : .greatestFiniteMagnitude
            var taken: [TimedWord] = []
            while cursor < words.count, words[cursor].start < upper {
                taken.append(words[cursor])
                cursor += 1
            }
            replies[index].words = taken
        }
        // Anything whisper timed past the last boundary still belongs to the
        // last reply of this channel.
        if cursor < words.count, let last = indices.last {
            replies[last].words += words[cursor...]
        }
    }

    /// The widest gap between consecutive words within `snapWindow` of `time`,
    /// never moving back past the previous boundary.
    private static func snap(_ time: TimeInterval, to words: [TimedWord],
                             after previous: TimeInterval?) -> TimeInterval {
        var best = time
        var widest = 0.0
        for pair in zip(words, words.dropFirst()) {
            let gap = pair.1.start - pair.0.end
            let middle = (pair.0.end + pair.1.start) / 2
            guard abs(middle - time) <= snapWindow, gap > widest else { continue }
            widest = gap
            best = middle
        }
        guard let previous else { return best }
        return max(best, previous)
    }

    // MARK: - Long replies

    /// Part of a reply, with the spans clipped to it, so a cut inside one long
    /// stretch of speech is possible at all.
    private struct Piece {
        let start: TimeInterval
        let end: TimeInterval
        let spans: [SpeechSpan]
        let words: [TimedWord]

        /// The two halves meeting at `cut`, or nil when everything said falls
        /// on one side of it.
        func divided(at cut: TimeInterval) -> (head: Piece, tail: Piece)? {
            guard cut > start, cut < end else { return nil }
            let before = words.filter { $0.start < cut }
            let after = words.filter { $0.start >= cut }
            guard !before.isEmpty, !after.isEmpty else { return nil }
            return (Piece(start: start, end: cut, spans: clip(spans, from: start, to: cut), words: before),
                    Piece(start: cut, end: end, spans: clip(spans, from: cut, to: end), words: after))
        }
    }

    /// A reply past `maxTurn` is cut so that a monologue carries timestamps
    /// too. Each half is reconsidered, which is what keeps a very long one from
    /// ending as a single block.
    private static func split(_ reply: Reply, speaker: Int) -> [SpeakerTurn] {
        var pending = [Piece(start: reply.start, end: reply.end,
                             spans: reply.spans, words: reply.words)]
        var turns: [SpeakerTurn] = []
        while !pending.isEmpty {
            let piece = pending.removeFirst()
            if piece.end - piece.start > maxTurn, piece.words.count > 1,
               let cut = cutPoint(piece), let halves = piece.divided(at: cut) {
                pending.insert(contentsOf: [halves.head, halves.tail], at: 0)
                continue
            }
            turns.append(SpeakerTurn(speaker: speaker, start: piece.start,
                                     text: SpeakerTranscriptBuilder.text(of: piece.words)))
        }
        return turns
    }

    /// Where to cut: as late as it can before the mark, and in a place the
    /// audio vouches for — the widest silence between spans, then a sentence
    /// end, then the widest gap between words, since a transcript can come back
    /// without a single full stop.
    ///
    /// Gaps in the last third of the window beat an earlier but wider pause.
    /// Taking the widest gap outright peels a monologue one span at a time,
    /// which is the very column of "Me" blocks this design set out to avoid.
    private static func cutPoint(_ piece: Piece) -> TimeInterval? {
        let target = piece.start + maxTurn
        let near = target - maxTurn / 3

        func best(_ gaps: [(at: TimeInterval, width: TimeInterval)]) -> TimeInterval? {
            let inside = gaps.filter { $0.at > piece.start && $0.at <= target }
            let late = inside.filter { $0.at >= near }
            return (late.isEmpty ? inside : late)
                .max { ($0.width, $0.at) < ($1.width, $1.at) }?.at
        }

        if let cut = best(gaps(between: piece.spans)) { return cut }
        if let cut = sentenceEnd(in: piece.words, between: piece.start, and: target) { return cut }
        return best(gaps(between: piece.words.map { SpeechSpan(start: $0.start, end: $0.end) }))
    }

    /// Where each silence between consecutive stretches begins, and how long it
    /// is. The cut goes at the start of what follows, so the next turn opens on
    /// a word.
    private static func gaps(between spans: [SpeechSpan]) -> [(at: TimeInterval, width: TimeInterval)] {
        zip(spans, spans.dropFirst())
            .map { (at: $1.start, width: $1.start - $0.end) }
            .filter { $0.width > 0 }
    }

    private static func sentenceEnd(in words: [TimedWord], between start: TimeInterval,
                                    and target: TimeInterval) -> TimeInterval? {
        var best: TimeInterval?
        for pair in zip(words, words.dropFirst()) where pair.1.start > start && pair.1.start <= target {
            if SpeakerTranscriptBuilder.endsSentence(pair.0.text) { best = pair.1.start }
        }
        return best
    }

    private static func clip(_ spans: [SpeechSpan], from: TimeInterval, to: TimeInterval) -> [SpeechSpan] {
        spans.compactMap {
            let start = max($0.start, from)
            let end = min($0.end, to)
            return end > start ? SpeechSpan(start: start, end: end) : nil
        }
    }
}
