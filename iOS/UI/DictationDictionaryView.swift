import SwiftUI
import UniformTypeIdentifiers

/// The dictation dictionary on iOS: terms every keyboard dictation hands
/// whisper as a prompt. Stored in the app group, where the host app reads it
/// for each transcription.
struct DictationDictionaryView: View {
    @EnvironmentObject var modelManager: ModelManager

    @State private var text = DictationDictionary.text
    @State private var enabled = DictationDictionary.isEnabled
    @State private var importing = false
    /// A file read but not applied yet: the user's own text is about to go.
    @State private var pendingImport: String?
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("dictation.dictionary.enabled".localized, isOn: $enabled)
                    .onChange(of: enabled) { DictationDictionary.isEnabled = $0 }
            } footer: {
                if let model = modelManager.activeModel, !model.supportsPrompt {
                    Text("dictation.dictionary.unsupported".localized(with: model.name))
                        .foregroundColor(.orange)
                }
            }

            Section {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 220)
                    .onChange(of: text) { DictationDictionary.text = $0 }
            } footer: {
                Text("vocab.count".localized(with: DictationDictionary.terms(from: text).count)
                     + "\n" + "dictation.dictionary.hint".localized)
            }

            Section {
                Button("dictation.dictionary.import".localized) { importing = true }
                ShareLink(item: text) {
                    Text("dictation.dictionary.export".localized)
                }
                Button("dictation.dictionary.reset".localized) {
                    if isUserText { confirmingReset = true } else { text = DictationDictionary.exampleText }
                }
                .disabled(text == DictationDictionary.exampleText)
            }
        }
        .navigationTitle("dictation.dictionary.title".localized)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try String(contentsOf: url, encoding: .utf8)
                if isUserText { pendingImport = imported } else { text = imported }
            } catch {
                flog("DictationDictionary: could not read \(url.lastPathComponent): \(error)")
            }
        }
        .alert("dictation.dictionary.replace.title".localized,
               isPresented: Binding(get: { pendingImport != nil || confirmingReset },
                                    set: { if !$0 { pendingImport = nil; confirmingReset = false } })) {
            Button("dictation.dictionary.replace.confirm".localized, role: .destructive) {
                text = pendingImport ?? DictationDictionary.exampleText
                pendingImport = nil
                confirmingReset = false
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("dictation.dictionary.replace.message".localized)
        }
    }

    /// Text the user wrote would be lost to an import or a reset; the example would not.
    private var isUserText: Bool {
        text != DictationDictionary.exampleText
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
