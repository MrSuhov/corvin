import Foundation

/// Drops speaker bleed from a call's microphone channel.
///
/// Without headphones the other side plays from the speakers and comes back in
/// through the microphone. Voice processing removes most of it; whatever
/// survives is transcribed a second time, as if the user had said it. The other
/// side's own channel is clean, so a microphone phrase whose words mostly also
/// appear there at the same moment is that echo.
enum EchoFilter {

    /// A pause this long ends a phrase. Echo is judged phrase by phrase, so an
    /// echoed sentence goes as a whole and a real reply next to it stays.
    static let phrasePause: TimeInterval = 0.6
    /// How far apart the same word may sit on the two channels: word
    /// timestamps are a few hundred ms off, plus the delay through the room.
    static let window: TimeInterval = 1.5
    /// Share of a phrase's words heard on the other channel that makes it echo.
    static let minShare = 0.6
    /// Bounds the search back from a word's start; no spoken word is longer.
    private static let longestWord: TimeInterval = 3

    private typealias Heard = (word: String, start: TimeInterval, end: TimeInterval)

    static func filter(me: [TimedWord], other: [TimedWord]) -> [TimedWord] {
        guard !me.isEmpty, !other.isEmpty else { return me }
        let reference: [Heard] = other
            .map { (normalize($0.text), $0.start, $0.end) }
            .filter { !$0.word.isEmpty }
            .sorted { $0.start < $1.start }

        var kept: [TimedWord] = []
        for phrase in phrases(me) {
            let words = phrase.filter { !normalize($0.text).isEmpty }
            guard !words.isEmpty else {
                kept += phrase
                continue
            }
            let echoed = words.filter { word in
                isHeard(normalize(word.text), from: word.start - window, to: word.end + window, in: reference)
            }.count
            if Double(echoed) / Double(words.count) < minShare {
                kept += phrase
            }
        }
        return kept
    }

    static func phrases(_ words: [TimedWord]) -> [[TimedWord]] {
        var result: [[TimedWord]] = []
        for word in words {
            if let last = result.last?.last, word.start - last.end <= phrasePause {
                result[result.count - 1].append(word)
            } else {
                result.append([word])
            }
        }
        return result
    }

    /// Case, punctuation and the dash whisper puts before a turn do not make
    /// two words different.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isHeard(_ word: String, from: TimeInterval, to: TimeInterval, in reference: [Heard]) -> Bool {
        let earliest = from - longestWord
        var low = 0
        var high = reference.count
        while low < high {
            let mid = (low + high) / 2
            if reference[mid].start < earliest { low = mid + 1 } else { high = mid }
        }
        var k = low
        while k < reference.count, reference[k].start <= to {
            if reference[k].end >= from, reference[k].word == word { return true }
            k += 1
        }
        return false
    }
}
