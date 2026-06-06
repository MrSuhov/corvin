import Foundation
import CoreData
import Combine

class HistoryStore: ObservableObject {
    @Published var records: [TranscriptionRecord] = []

    private let container: NSPersistentContainer

    init() {
        // Create managed object model programmatically
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "TranscriptionRecordEntity"
        entity.managedObjectClassName = NSStringFromClass(TranscriptionRecordEntity.self)

        let idAttr = NSAttributeDescription()
        idAttr.name = "id"
        idAttr.attributeType = .UUIDAttributeType

        let textAttr = NSAttributeDescription()
        textAttr.name = "text"
        textAttr.attributeType = .stringAttributeType

        let dateAttr = NSAttributeDescription()
        dateAttr.name = "date"
        dateAttr.attributeType = .dateAttributeType

        let durationAttr = NSAttributeDescription()
        durationAttr.name = "duration"
        durationAttr.attributeType = .doubleAttributeType

        let modelAttr = NSAttributeDescription()
        modelAttr.name = "modelUsed"
        modelAttr.attributeType = .stringAttributeType

        let langAttr = NSAttributeDescription()
        langAttr.name = "language"
        langAttr.attributeType = .stringAttributeType

        entity.properties = [idAttr, textAttr, dateAttr, durationAttr, modelAttr, langAttr]
        model.entities = [entity]

        container = NSPersistentContainer(name: "Corvin", managedObjectModel: model)

        let description = NSPersistentStoreDescription()
        let storeURL: URL
        #if os(iOS)
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.corvinvoice.app") {
            storeURL = groupURL.appendingPathComponent("Corvin.sqlite")
        } else {
            storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Corvin/Corvin.sqlite")
        }
        #else
        storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Corvin/Corvin.sqlite")
        #endif
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        description.url = storeURL
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error = error {
                print("Core Data error: \(error)")
            }
        }

        fetchRecords()
    }

    private var context: NSManagedObjectContext {
        container.viewContext
    }

    func addRecord(text: String, duration: TimeInterval, modelUsed: String, language: String) {
        let entity = TranscriptionRecordEntity(context: context)
        entity.id = UUID()
        entity.text = text
        entity.date = Date()
        entity.duration = duration
        entity.modelUsed = modelUsed
        entity.language = language

        saveAndFetch()
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        let request = NSFetchRequest<TranscriptionRecordEntity>(entityName: "TranscriptionRecordEntity")
        request.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        if let entities = try? context.fetch(request), let entity = entities.first {
            context.delete(entity)
            saveAndFetch()
        }
    }

    func deleteAll() {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "TranscriptionRecordEntity")
        let batch = NSBatchDeleteRequest(fetchRequest: request)
        _ = try? context.execute(batch)
        saveAndFetch()
    }

    func performAutoCleanup() {
        #if os(iOS)
        let defaults = UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        let defaults = UserDefaults.standard
        #endif
        let period = defaults.string(forKey: "autoCleanupPeriod") ?? "never"
        let cutoff: Date?

        switch period {
        case "week": cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: Date())
        case "month": cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date())
        case "halfYear": cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date())
        default: cutoff = nil
        }

        guard let cutoff = cutoff else { return }

        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "TranscriptionRecordEntity")
        request.predicate = NSPredicate(format: "date < %@", cutoff as NSDate)
        let batch = NSBatchDeleteRequest(fetchRequest: request)
        _ = try? context.execute(batch)
        saveAndFetch()
    }

    func searchRecords(_ query: String) -> [TranscriptionRecord] {
        if query.isEmpty { return records }
        return records.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    func exportRecords(_ records: [TranscriptionRecord]) -> String {
        records.map { record in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "[\(formatter.string(from: record.date))] (\(record.language), \(String(format: "%.1f", record.duration))с)\n\(record.text)"
        }.joined(separator: "\n\n---\n\n")
    }

    private func saveAndFetch() {
        try? context.save()
        fetchRecords()
    }

    private func fetchRecords() {
        let request = NSFetchRequest<TranscriptionRecordEntity>(entityName: "TranscriptionRecordEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptionRecordEntity.date, ascending: false)]

        guard let entities = try? context.fetch(request) else { return }
        records = entities.map { entity in
            TranscriptionRecord(
                id: entity.id ?? UUID(),
                text: entity.text ?? "",
                date: entity.date ?? Date(),
                duration: entity.duration,
                modelUsed: entity.modelUsed ?? "",
                language: entity.language ?? ""
            )
        }
    }
}

struct TranscriptionRecord: Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let duration: TimeInterval
    let modelUsed: String
    let language: String
}

class TranscriptionRecordEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var text: String?
    @NSManaged var date: Date?
    @NSManaged var duration: Double
    @NSManaged var modelUsed: String?
    @NSManaged var language: String?
}
