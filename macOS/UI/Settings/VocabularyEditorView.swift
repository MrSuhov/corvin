import SwiftUI

/// Sheet for creating and editing term vocabularies used by file transcription.
struct VocabularyEditorView: View {
    @EnvironmentObject var vocabularies: VocabularyStore
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine
    // `dismiss` is macOS 12+.
    @Environment(\.presentationMode) private var presentationMode

    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var termsText = ""
    /// Terms that fit the prompt, when the model is loaded to count them.
    @State private var usedTerms: Int?
    /// Bumped per edit so a slow count for older text never overwrites a newer one.
    @State private var fitGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("vocab.title".localized)
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                sidebar
                    .frame(width: 180)
                editor
            }

            HStack {
                Spacer()
                Button("vocab.done".localized) {
                    commit()
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 440)
        .onAppear {
            select(vocabularies.activeID ?? vocabularies.vocabularies.first?.id)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: Binding(get: { selectedID }, set: { id in
                commit()
                select(id)
            })) {
                ForEach(vocabularies.vocabularies) { vocabulary in
                    Text(vocabulary.name).tag(Optional(vocabulary.id))
                }
            }
            .modifier(BorderedListCompat())

            HStack(spacing: 4) {
                Button {
                    commit()
                    select(vocabularies.create(name: "vocab.new".localized).id)
                } label: {
                    Image(systemName: "plus")
                }
                .help("vocab.add".localized)

                Button {
                    guard let id = selectedID else { return }
                    vocabularies.delete(id)
                    select(vocabularies.vocabularies.first?.id)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedID == nil)
                .help("vocab.delete".localized)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if selectedID == nil {
            Text("vocab.empty".localized)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                TextField("vocab.name".localized, text: $name)

                Text("vocab.terms".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $termsText)
                    .font(.body)
                    .border(Color.secondary.opacity(0.3))
                    .onChange(of: termsText) { _ in scheduleFit() }

                Text(countLabel)
                    .font(.caption)
                    .foregroundColor(isTrimmed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("vocab.hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var terms: [String] { VocabularyStore.parseTerms(termsText) }

    private var isTrimmed: Bool {
        usedTerms.map { $0 < terms.count } ?? false
    }

    private var countLabel: String {
        if let used = usedTerms, used < terms.count {
            return "vocab.fit".localized(with: used, terms.count)
        }
        return "vocab.count".localized(with: terms.count)
    }

    // MARK: - State

    private func select(_ id: UUID?) {
        selectedID = id
        let vocabulary = vocabularies.vocabularies.first { $0.id == id }
        name = vocabulary?.name ?? ""
        termsText = vocabulary?.terms.joined(separator: "\n") ?? ""
        usedTerms = nil
        scheduleFit()
    }

    private func commit() {
        guard let id = selectedID,
              var vocabulary = vocabularies.vocabularies.first(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        vocabulary.name = trimmedName.isEmpty ? vocabulary.name : trimmedName
        vocabulary.terms = terms
        guard vocabulary != vocabularies.vocabularies.first(where: { $0.id == id }) else { return }
        vocabularies.update(vocabulary)
    }

    /// Counts how many terms fit whisper's prompt. Only with a model already
    /// in memory: loading one just to count would take seconds and gigabytes.
    private func scheduleFit() {
        fitGeneration += 1
        let generation = fitGeneration
        let current = terms
        guard transcriptionEngine.isModelLoaded, !current.isEmpty else {
            usedTerms = nil
            return
        }
        let engine = transcriptionEngine
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            guard let fitted = try? engine.fitPrompt(terms: current) else { return }
            DispatchQueue.main.async {
                guard generation == fitGeneration else { return }
                usedTerms = fitted.used
            }
        }
    }
}

/// `.listStyle(.bordered)` is macOS 12+.
private struct BorderedListCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.listStyle(.bordered)
        } else {
            content
        }
    }
}
