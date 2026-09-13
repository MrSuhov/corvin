import Foundation

/// A recognised word with its position in the session's audio, in seconds.
struct TimedWord: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Decides which words of a sliding-window transcription are stable.
///
/// LocalAgreement-2 (Macháček et al., "Turning Whisper into Real-Time
/// Transcription System", 2023): re-transcribing a growing buffer keeps
/// revising its last few words, but a word that two consecutive runs agree on
/// has stopped changing. Such a prefix is committed and never revisited.
///
/// Pure value type with no audio or engine dependency, so its behaviour can be
/// checked on hand-written hypotheses.
struct HypothesisBuffer {
    private(set) var committed: [TimedWord] = []
    /// The uncommitted rest of the previous hypothesis.
    private var pending: [TimedWord] = []

    /// End of the last committed word; audio before it is settled.
    private(set) var committedEnd: TimeInterval = 0

    /// Feeds the words of a new run over the buffer, with session-absolute
    /// times. Returns the words this run committed.
    mutating func insert(_ words: [TimedWord]) -> [TimedWord] {
        // A window that still starts before the commit point re-transcribes
        // settled audio; its words there are already committed.
        var incoming = words.filter { $0.start > committedEnd - 0.1 }
        dropRepeatedCommittedTail(from: &incoming)

        var newlyCommitted: [TimedWord] = []
        while let word = incoming.first, let previous = pending.first,
              Self.normalized(word.text) == Self.normalized(previous.text) {
            newlyCommitted.append(word)
            incoming.removeFirst()
            pending.removeFirst()
        }

        committed += newlyCommitted
        if let last = newlyCommitted.last {
            committedEnd = last.end
        }
        pending = incoming
        return newlyCommitted
    }

    /// Commits whatever the latest run left pending. Called once the audio has
    /// ended and there will be no second opinion.
    mutating func flush() -> [TimedWord] {
        let tail = pending
        pending = []
        committed += tail
        if let last = tail.last {
            committedEnd = last.end
        }
        return tail
    }

    /// Commits the pending words that end by `time` without waiting for a
    /// second run to agree. The escape hatch for a window about to outgrow
    /// whisper's 30-second context while one run keeps revising itself.
    mutating func commit(through time: TimeInterval) -> [TimedWord] {
        let count = pending.prefix { $0.end <= time }.count
        let forced = Array(pending.prefix(count))
        pending.removeFirst(count)
        committed += forced
        if let last = forced.last {
            committedEnd = last.end
        }
        return forced
    }

    /// Word timestamps are coarse, so the time filter can let through the last
    /// one or two committed words again. Match them as an n-gram right at the
    /// seam and drop them.
    private func dropRepeatedCommittedTail(from incoming: inout [TimedWord]) {
        guard let first = incoming.first, !committed.isEmpty,
              abs(first.start - committedEnd) < 1 else { return }
        let maxN = min(5, committed.count, incoming.count)
        guard maxN > 0 else { return }
        for n in stride(from: maxN, through: 1, by: -1) {
            let tail = committed.suffix(n).map { Self.normalized($0.text) }
            let head = incoming.prefix(n).map { Self.normalized($0.text) }
            if tail == head {
                incoming.removeFirst(n)
                return
            }
        }
    }

    /// Two runs often differ only in punctuation or case on the same word;
    /// that must not block agreement.
    static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespaces.contains($0)
        })
    }
}
