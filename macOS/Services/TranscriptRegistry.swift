import Foundation
import AppKit
import Combine

/// Which transcript of an audio file: plain text, or a script split by speaker.
enum TranscriptMode: String, Codable {
    case plain
    case roles
    /// A call recording: roles from its two channels, filed as a roles transcript.
    case call

    /// `talk.txt` vs `talk_roles.txt`.
    var fileSuffix: String { self == .plain ? "" : "_roles" }
}

/// Every audio file Corvin has transcribed, persisted so the Transcription
/// pane can offer "transcribe again" across launches and flag a source that
/// changed after its transcript was made.
///
/// Change detection is size plus modification date, taken when the file was
/// read for transcription. Hashing would also catch a same-size rewrite that
/// kept its mtime, but costs a full read of every listed file each time the
/// pane appears.
@MainActor
final class TranscriptRegistry: ObservableObject {

    struct Variant: Codable, Equatable {
        let outputPath: String
        let sourceSize: Int64
        let sourceModified: Date
        let dictionaryName: String?
        let date: Date
        /// The roles slot also holds call transcripts; this is what tells
        /// "transcribe again" to read the channels again instead of mixing
        /// them down. Absent in files written before call recording existed.
        var isCall: Bool?

        var outputURL: URL { URL(fileURLWithPath: outputPath) }
    }

    struct Record: Codable, Equatable, Identifiable {
        let sourcePath: String
        var plain: Variant?
        var roles: Variant?
        var updatedAt: Date

        var id: String { sourcePath }
        var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

        subscript(mode: TranscriptMode) -> Variant? {
            get { mode == .plain ? plain : roles }
            set { if mode == .plain { plain = newValue } else { roles = newValue } }
        }
    }

    enum SourceState: Equatable {
        case unchanged
        /// Differs from what this transcript was made from.
        case changed
        case missing
    }

    /// What a source file looked like at one moment.
    struct SourceStamp: Equatable {
        let size: Int64
        let modified: Date

        static func read(_ url: URL) -> SourceStamp? {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }
            return SourceStamp(size: Int64(size), modified: modified)
        }

        func matches(_ variant: Variant) -> Bool {
            // Filesystems store mtime at different precisions; a real edit
            // moves it by far more than a second.
            size == variant.sourceSize && abs(modified.timeIntervalSince(variant.sourceModified)) < 1
        }
    }

    /// Most recently transcribed first.
    @Published private(set) var records: [Record] = []
    @Published private(set) var states: [String: [TranscriptMode: SourceState]] = [:]

    private let file: URL
    private var cancellables = Set<AnyCancellable>()

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Corvin/transcripts.json")
        load()
        refreshSourceStates()

        // Coming back to the app is when a file is most likely to have been
        // edited or moved elsewhere.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshSourceStates() }
            .store(in: &cancellables)
    }

    func state(of record: Record, _ mode: TranscriptMode) -> SourceState? {
        states[record.sourcePath]?[mode]
    }

    /// The mode a file has to be transcribed in again, if it is remembered as
    /// a call recording.
    func mode(for source: URL) -> TranscriptMode? {
        let path = source.standardizedFileURL.path
        guard let record = records.first(where: { $0.sourcePath == path }) else { return nil }
        return record.roles?.isCall == true ? .call : nil
    }

    func add(source: URL, mode: TranscriptMode, output: URL, stamp: SourceStamp, dictionaryName: String?) {
        let path = source.standardizedFileURL.path
        var record = records.first { $0.sourcePath == path }
            ?? Record(sourcePath: path, plain: nil, roles: nil, updatedAt: Date())
        record[mode] = Variant(outputPath: output.path, sourceSize: stamp.size,
                               sourceModified: stamp.modified, dictionaryName: dictionaryName, date: Date(),
                               isCall: mode == .call)
        record.updatedAt = Date()
        records.removeAll { $0.sourcePath == path }
        records.insert(record, at: 0)
        persist()
        refreshSourceStates()
    }

    /// Forgets the file. Its transcripts stay on disk.
    func remove(_ record: Record) {
        records.removeAll { $0.sourcePath == record.sourcePath }
        states[record.sourcePath] = nil
        persist()
    }

    func removeAll() {
        records = []
        states = [:]
        persist()
    }

    func refreshSourceStates() {
        var result: [String: [TranscriptMode: SourceState]] = [:]
        for record in records {
            let stamp = SourceStamp.read(record.sourceURL)
            var modes: [TranscriptMode: SourceState] = [:]
            for mode in [TranscriptMode.plain, .roles] {
                guard let variant = record[mode] else { continue }
                guard let stamp else {
                    modes[mode] = .missing
                    continue
                }
                modes[mode] = stamp.matches(variant) ? .unchanged : .changed
            }
            result[record.sourcePath] = modes
        }
        states = result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            records = try JSONDecoder().decode([Record].self, from: data)
        } catch {
            flog("TranscriptRegistry: could not read \(file.path): \(error)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        } catch {
            flog("TranscriptRegistry: could not write \(file.path): \(error)")
        }
    }
}
