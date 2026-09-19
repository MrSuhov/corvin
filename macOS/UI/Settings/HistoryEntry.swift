import Foundation

/// One row of the Files tab: an audio file Corvin recorded, transcribed or is
/// transcribing, with whatever is known about it.
///
/// Three sources, because none alone is complete: `CallIndex` knows the calls
/// (including ones not transcribed yet), `TranscriptRegistry` knows the
/// transcripts (including ones of files the user imported), and the queue
/// knows a file just added, which has no transcript until it is done.
struct HistoryEntry: Identifiable, Equatable {
    let path: String
    let call: CallInfo?
    let record: TranscriptRegistry.Record?
    /// The latest job for this file, running or finished; kept in memory only.
    var job: FileTranscriptionQueue.Job? = nil

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// A call recording rather than an imported file. The registry remembers
    /// this too, for calls recorded before the index existed.
    var isCall: Bool { call != nil || record?.roles?.isCall == true || job?.mode == .call }

    /// A job for this file is waiting or running.
    var isQueued: Bool { job.map { !$0.status.isFinished } ?? false }

    var fileName: String { url.lastPathComponent }

    /// The app a call came from, when it is known.
    var appName: String? {
        guard let name = call?.appName, !name.isEmpty else { return nil }
        return name
    }

    /// Newest first uses this: when the call started, else when the file was
    /// last transcribed or added.
    var date: Date {
        if let started = call?.startedAt { return started }
        return max(record?.updatedAt ?? .distantPast, job?.queuedAt ?? .distantPast)
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

    static func merge(records: [TranscriptRegistry.Record], calls: [String: CallInfo],
                      jobs: [FileTranscriptionQueue.Job] = []) -> [HistoryEntry] {
        var byPath: [String: HistoryEntry] = [:]
        for record in records {
            let path = URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path
            byPath[path] = HistoryEntry(path: path, call: calls[path], record: record)
        }
        for (path, call) in calls where byPath[path] == nil {
            byPath[path] = HistoryEntry(path: path, call: call, record: nil)
        }
        // In queue order, so the last job for a file is the one kept.
        for job in jobs {
            let path = job.url.standardizedFileURL.path
            var entry = byPath[path] ?? HistoryEntry(path: path, call: calls[path], record: nil)
            entry.job = job
            byPath[path] = entry
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
