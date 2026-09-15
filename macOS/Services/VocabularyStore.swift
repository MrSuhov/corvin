import Foundation

/// A named list of terms whisper should expect: project names, people,
/// jargon. Given to the decoder as a prompt before every chunk.
struct Vocabulary: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var terms: [String]

    init(id: UUID = UUID(), name: String, terms: [String] = []) {
        self.id = id
        self.name = name
        self.terms = terms
    }
}

/// The user's vocabularies, in `~/Library/Application Support/Corvin/vocabularies.json`,
/// and which one file transcription uses. Local only, like everything else.
@MainActor
final class VocabularyStore: ObservableObject {

    @Published private(set) var vocabularies: [Vocabulary] = []

    /// Vocabulary new file jobs use; nil for none.
    @Published var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    static let activeKey = "fileTranscription.vocabularyID"

    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Corvin/vocabularies.json")
        load()
        let stored = UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        activeID = vocabularies.contains { $0.id == stored } ? stored : nil
    }

    var active: Vocabulary? {
        vocabularies.first { $0.id == activeID }
    }

    @discardableResult
    func create(name: String) -> Vocabulary {
        let vocabulary = Vocabulary(name: name)
        vocabularies.append(vocabulary)
        persist()
        return vocabulary
    }

    func update(_ vocabulary: Vocabulary) {
        guard let index = vocabularies.firstIndex(where: { $0.id == vocabulary.id }) else { return }
        vocabularies[index] = vocabulary
        persist()
    }

    func delete(_ id: UUID) {
        vocabularies.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        persist()
    }

    /// One term per line; commas and semicolons separate terms too, so a list
    /// pasted from a document works. Blank and repeated (case-insensitive)
    /// entries are dropped, first spelling wins.
    static func parseTerms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: "\n\r,;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            vocabularies = try JSONDecoder().decode([Vocabulary].self, from: data)
        } catch {
            flog("VocabularyStore: could not read \(file.path): \(error)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(vocabularies).write(to: file, options: .atomic)
        } catch {
            flog("VocabularyStore: could not write \(file.path): \(error)")
        }
    }
}
