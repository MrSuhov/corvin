import Foundation

/// A stretch of audio that diarization attributes to one voice.
struct SpeakerSegment: Equatable {
    /// Diarizer's label ("S1", …). Opaque: only equality matters.
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// One reply of a roles transcript.
struct SpeakerTurn: Equatable {
    /// 1-based, numbered in order of first appearance.
    let speaker: Int
    let start: TimeInterval
    let text: String
}

/// Turns whisper's timed words plus diarization's speaker segments into
/// replies, as in a script.
///
/// Pure value logic with no audio or engine dependency, so its behaviour can be
/// checked on hand-written words and segments. The rules were tuned on real
/// meeting recordings (see docs/plans/2026-09-15-dialog-transcription-design.md):
///
/// 1. Each word goes to the speaker whose segment overlaps it most.
/// 2. Word timestamps are a few hundred ms off, so a raw speaker change tends to
///    cut a phrase in two. Changes move to the nearest sentence end within
///    `snapWindow`, else to the widest pause.
/// 3. A run shorter than `shortRun` between two runs of the same speaker is
///    noise and is absorbed.
/// 4. Diarization merges 1–2 s replies into the neighbour, but whisper still
///    hears the turn and starts the reply with a dash. Runs are split there;
///    a piece goes to a diarized speaker owning `minShare` of it, otherwise
///    pieces alternate with the previous interlocutor.
enum SpeakerTranscriptBuilder {

    static let snapWindow: TimeInterval = 1.0
    static let shortRun: TimeInterval = 0.7
    static let minShare = 0.25

    private static let sentenceEnd: Set<Character> = [".", "?", "!", "…"]
    private static let dashes: Set<Character> = ["-", "–", "—"]

    private struct Run {
        var speaker: String
        var words: [TimedWord]
        var start: TimeInterval { words.first?.start ?? 0 }
        var end: TimeInterval { words.last?.end ?? 0 }
    }

    static func build(words: [TimedWord], segments: [SpeakerSegment]) -> [SpeakerTurn] {
        guard !words.isEmpty else { return [] }
        let segments = segments.sorted { $0.start < $1.start }
        guard !segments.isEmpty else {
            return [SpeakerTurn(speaker: 1, start: words[0].start, text: text(of: words))]
        }

        var labels = words.map { speaker(for: $0, in: segments) }
        snapBoundaries(words, &labels)
        let runs = splitInterruptions(absorbShortRuns(makeRuns(words, labels)), segments)

        var numbers: [String: Int] = [:]
        return runs.compactMap { run in
            let body = text(of: run.words)
            guard !body.isEmpty else { return nil }
            let number = numbers[run.speaker] ?? (numbers.count + 1)
            numbers[run.speaker] = number
            return SpeakerTurn(speaker: number, start: run.start, text: body)
        }
    }

    // MARK: - 1. Attribution

    private static func speaker(for word: TimedWord, in segments: [SpeakerSegment]) -> String {
        var best: String?
        var bestOverlap: TimeInterval = 0
        for segment in segments {
            let overlap = min(word.end, segment.end) - max(word.start, segment.start)
            if overlap > bestOverlap {
                best = segment.speaker
                bestOverlap = overlap
            }
        }
        if let best { return best }

        // In a gap between segments: the closest one.
        let mid = (word.start + word.end) / 2
        func distance(_ s: SpeakerSegment) -> TimeInterval { min(abs(mid - s.start), abs(mid - s.end)) }
        return segments.min { distance($0) < distance($1) }!.speaker
    }

    // MARK: - 2. Boundary snapping

    private static func snapBoundaries(_ words: [TimedWord], _ labels: inout [String]) {
        func gap(before k: Int) -> TimeInterval {
            k < words.count ? words[k].start - words[k - 1].end : -1
        }

        var i = 1
        while i < words.count {
            guard labels[i] != labels[i - 1] else {
                i += 1
                continue
            }
            let t = words[i].start
            var lo = i
            while lo > 1, t - words[lo - 1].start <= snapWindow { lo -= 1 }
            var hi = i
            while hi < words.count - 1, words[hi].start - t <= snapWindow { hi += 1 }

            // Cut k: words before k keep the left speaker, from k on the right.
            let candidates = Array(lo...hi)
            let cut = candidates.filter { endsSentence(words[$0 - 1].text) }
                .min { abs($0 - i) < abs($1 - i) }
                ?? candidates.max { gap(before: $0) < gap(before: $1) }!

            let left = labels[i - 1]
            let right = labels[i]
            for j in lo...hi where labels[j] == left || labels[j] == right {
                labels[j] = j < cut ? left : right
            }
            i = max(cut, i) + 1
        }
    }

    // MARK: - 3. Runs

    private static func makeRuns(_ words: [TimedWord], _ labels: [String]) -> [Run] {
        var runs: [Run] = []
        for (word, label) in zip(words, labels) {
            if runs.last?.speaker == label {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append(Run(speaker: label, words: [word]))
            }
        }
        return runs
    }

    private static func absorbShortRuns(_ input: [Run]) -> [Run] {
        var runs = input
        var i = 1
        while i < runs.count - 1 {
            let run = runs[i]
            if run.end - run.start < shortRun,
               runs[i - 1].speaker == runs[i + 1].speaker,
               runs[i - 1].speaker != run.speaker {
                runs[i - 1].words += run.words + runs[i + 1].words
                runs.removeSubrange(i...(i + 1))
                i = max(1, i - 1)
            } else {
                i += 1
            }
        }
        return runs
    }

    // MARK: - 4. Interruptions

    private static func splitInterruptions(_ runs: [Run], _ segments: [SpeakerSegment]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            var pieces: [[TimedWord]] = []
            var current: [TimedWord] = []
            for (k, word) in run.words.enumerated() {
                if !current.isEmpty, startsDashTurn(run.words, at: k) {
                    pieces.append(current)
                    current = []
                }
                current.append(word)
            }
            pieces.append(current)

            guard pieces.count > 1 else {
                append(run, to: &out)
                continue
            }

            var other = out.last { $0.speaker != run.speaker }?.speaker
            var speaker = run.speaker
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    if let strong = dominantOtherSpeaker(of: piece, besides: speaker, in: segments) {
                        speaker = strong
                    } else if let previous = other {
                        other = speaker
                        speaker = previous
                    }
                }
                append(Run(speaker: speaker, words: piece), to: &out)
            }
        }
        return out
    }

    /// Whisper opens a reply inside a merged segment with a dash right after
    /// the previous sentence (or clause) ends.
    private static func startsDashTurn(_ words: [TimedWord], at k: Int) -> Bool {
        guard let first = words[k].text.first, dashes.contains(first) else { return false }
        guard k > 0 else { return true }
        guard let last = words[k - 1].text.last else { return false }
        return sentenceEnd.contains(last) || last == ","
    }

    private static func dominantOtherSpeaker(of piece: [TimedWord], besides speaker: String,
                                             in segments: [SpeakerSegment]) -> String? {
        guard let start = piece.first?.start, let end = piece.last?.end else { return nil }
        var share: [String: TimeInterval] = [:]
        for segment in segments where segment.speaker != speaker {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > 0 { share[segment.speaker, default: 0] += overlap }
        }
        let span = max(end - start, 0.001)
        return share.filter { $0.value / span >= minShare }.max { $0.value < $1.value }?.key
    }

    private static func append(_ run: Run, to runs: inout [Run]) {
        if runs.last?.speaker == run.speaker {
            runs[runs.count - 1].words += run.words
        } else {
            runs.append(run)
        }
    }

    // MARK: - Text

    static func endsSentence(_ word: String) -> Bool {
        word.last.map(sentenceEnd.contains) ?? false
    }

    static func text(of words: [TimedWord]) -> String {
        let joined = words.map(\.text).joined(separator: " ")
        // The dash that marked the turn is not part of what was said.
        return String(joined.drop { dashes.contains($0) || $0 == " " })
    }
}

/// `SpeakerTurn`s as a script: timestamp and speaker on one line, the reply
/// below, a blank line between replies.
enum RolesFormatter {

    static func format(_ turns: [SpeakerTurn]) -> String {
        format(turns) { "roles.speaker".localized(with: $0) }
    }

    /// - Parameter label: the name a speaker number is shown under.
    static func format(_ turns: [SpeakerTurn], label: (Int) -> String) -> String {
        guard !turns.isEmpty else { return "" }
        return turns.map { turn in
            "[\(timestamp(turn.start))] \(label(turn.speaker)):\n\(turn.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// `1:02:03`, or `2:03` for anything under an hour — a length, not a
    /// position, so it is not zero-padded.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
