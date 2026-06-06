import SwiftUI
import UniformTypeIdentifiers

struct HistoryWindowView: View {
    @EnvironmentObject var historyStore: HistoryStore
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var searchText = ""
    @State private var expandedRecord: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Поиск...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))

            Divider()

            // Records list grouped by day
            if filteredRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Нет записей")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { day, records in
                        Section(header: Text(day)) {
                            ForEach(records) { record in
                                RecordRowView(
                                    record: record,
                                    isExpanded: expandedRecord == record.id,
                                    onTap: {
                                        withAnimation {
                                            expandedRecord = expandedRecord == record.id ? nil : record.id
                                        }
                                    },
                                    onCopy: { copyRecord(record) },
                                    onDelete: { historyStore.deleteRecord(record) }
                                )
                            }
                        }
                    }
                }
            }

            Divider()

            // Bottom toolbar
            HStack {
                Text("\(filteredRecords.count) записей")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Экспорт") {
                    exportRecords()
                }
                Button("Очистить всё") {
                    historyStore.deleteAll()
                }
                .foregroundColor(.red)
            }
            .padding(8)
        }
        .frame(minWidth: 400, minHeight: 500)
        .id(localization.currentLanguage)
    }

    private var filteredRecords: [TranscriptionRecord] {
        historyStore.searchRecords(searchText)
    }

    private var groupedByDay: [(String, [TranscriptionRecord])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let grouped = Dictionary(grouping: filteredRecords) { record in
            formatter.string(from: record.date)
        }
        return grouped.sorted { $0.value.first!.date > $1.value.first!.date }
    }

    private func copyRecord(_ record: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    private func exportRecords() {
        let text = historyStore.exportRecords(filteredRecords)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "corvin-export.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct RecordRowView: View {
    let record: TranscriptionRecord
    let isExpanded: Bool
    let onTap: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.text)
                        .lineLimit(isExpanded ? nil : 2)
                        .font(.body)

                    HStack(spacing: 8) {
                        Text(timeString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1fс", record.duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(record.language.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(3)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: record.date)
    }
}
