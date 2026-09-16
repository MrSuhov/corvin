import Foundation

/// One row of the History tab: an audio file Corvin recorded or transcribed,
/// with whatever is known about it.
///
/// Two sources, because neither alone is complete: `CallIndex` knows the calls
/// (including ones not transcribed yet), `TranscriptRegistry` knows the
/// transcripts (including ones of files the user imported).
struct HistoryEntry: Identifiable, Equatable {
    let path: String
    let call: CallInfo?
    let record: TranscriptRegistry.Record?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// A call recording rather than an imported file. The registry remembers
    /// this too, for calls recorded before the index existed.
    var isCall: Bool { call != nil || record?.roles?.isCall == true }

    var fileName: String { url.lastPathComponent }

    /// The app a call came from, when it is known.
    var appName: String? {
        guard let name = call?.appName, !name.isEmpty else { return nil }
        return name
    }

    /// Newest first uses this: when the call started, else when its transcript
    /// was last written.
    var date: Date {
        call?.startedAt ?? record?.updatedAt ?? .distantPast
    }

    var duration: TimeInterval? { call?.duration }

    /// The transcripts this file has, in a stable order.
    var variants: [(mode: TranscriptMode, variant: TranscriptRegistry.Variant)] {
        guard let record else { return [] }
        var result: [(TranscriptMode, TranscriptRegistry.Variant)] = []
        if let plain = record.plain { result.append((.plain, plain)) }
        if let roles = record.roles { result.append((roles.isCall == true ? .call : .roles, roles)) }
        return result.map { (mode: $0.0, variant: $0.1) }
    }

    static func merge(records: [TranscriptRegistry.Record], calls: [String: CallInfo]) -> [HistoryEntry] {
        var byPath: [String: HistoryEntry] = [:]
        for record in records {
            let path = URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path
            byPath[path] = HistoryEntry(path: path, call: calls[path], record: record)
        }
        for (path, call) in calls where byPath[path] == nil {
            byPath[path] = HistoryEntry(path: path, call: call, record: nil)
        }
        return byPath.values.sorted {
            $0.date == $1.date ? $0.path < $1.path : $0.date > $1.date
        }
    }

    /// `1:02:03`, or `2:03` for anything under an hour.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        RolesFormatter.duration(seconds)
    }
}
