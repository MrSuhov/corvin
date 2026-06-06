import SwiftUI

struct iOSHistoryView: View {
    @EnvironmentObject var historyStore: HistoryStore
    @State private var searchText = ""

    private var filteredRecords: [TranscriptionRecord] {
        historyStore.searchRecords(searchText)
    }

    var body: some View {
        NavigationView {
            Group {
                if filteredRecords.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Нет записей")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(filteredRecords) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.text)
                                    .lineLimit(3)
                                HStack {
                                    Text(record.date, style: .date)
                                    Text("•")
                                    Text(String(format: "%.1fс", record.duration))
                                    Text("•")
                                    Text(record.language)
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = record.text
                                } label: {
                                    Label("Копировать", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    historyStore.deleteRecord(record)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Поиск")
            .navigationTitle("История")
            .toolbar {
                if !historyStore.records.isEmpty {
                    Button(role: .destructive) {
                        historyStore.deleteAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}
