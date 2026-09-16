import Foundation

/// A call's script, built from its two channels.
///
/// The channels already say who is who: the microphone is the user, the app's
/// audio is everyone else. Diarization only has to tell the other side's voices
/// apart in a group call, and it runs on that channel alone.
///
/// Speaker numbers in the result: `me` (1) is the user; 2, 3… are the other
/// side in order of first appearance.
enum CallTranscriptBuilder {

    static let me = 1

    /// - Parameters:
    ///   - me: the microphone channel's words, already through `EchoFilter`.
    ///   - other: the app channel's words.
    ///   - otherSegments: diarization of the app channel; empty for one voice.
    static func build(me: [TimedWord], other: [TimedWord], otherSegments: [SpeakerSegment]) -> [SpeakerTurn] {
        let otherTurns = SpeakerTranscriptBuilder.build(words: other, segments: otherSegments)
            .map { SpeakerTurn(speaker: $0.speaker + 1, start: $0.start, text: $0.text) }
        let myTurns = split(me, at: otherTurns.map(\.start))
        let ordered = (myTurns + otherTurns).sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        return joinAdjacent(ordered)
    }

    /// The script with "Me" / "Other", or "Other 1", "Other 2" once the other
    /// side has more than one voice.
    static func format(_ turns: [SpeakerTurn]) -> String {
        let others = Set(turns.map(\.speaker)).subtracting([me]).count
        return RolesFormatter.format(turns) { speaker in
            if speaker == me { return "roles.me".localized }
            return others > 1 ? "roles.otherNumbered".localized(with: speaker - 1) : "roles.other".localized
        }
    }

    /// The user's words as replies: everything said between two replies of the
    /// other side is one reply.
    private static func split(_ words: [TimedWord], at boundaries: [TimeInterval]) -> [SpeakerTurn] {
        let boundaries = boundaries.sorted()
        var turns: [SpeakerTurn] = []
        var current: [TimedWord] = []
        var currentSlot = -1
        var slot = 0
        for word in words {
            while slot < boundaries.count, boundaries[slot] <= word.start { slot += 1 }
            if slot != currentSlot, !current.isEmpty {
                turns.append(turn(of: current))
                current = []
            }
            currentSlot = slot
            current.append(word)
        }
        if !current.isEmpty { turns.append(turn(of: current)) }
        return turns
    }

    private static func turn(of words: [TimedWord]) -> SpeakerTurn {
        SpeakerTurn(speaker: me, start: words[0].start, text: SpeakerTranscriptBuilder.text(of: words))
    }

    /// A pause is not a change of speaker: consecutive replies of one speaker
    /// read as one paragraph.
    private static func joinAdjacent(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var result: [SpeakerTurn] = []
        for turn in turns where !turn.text.isEmpty {
            if let last = result.last, last.speaker == turn.speaker {
                result[result.count - 1] = SpeakerTurn(speaker: last.speaker, start: last.start,
                                                       text: last.text + " " + turn.text)
            } else {
                result.append(turn)
            }
        }
        return result
    }
}
