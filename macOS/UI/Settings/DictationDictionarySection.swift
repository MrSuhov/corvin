import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The dictation dictionary: terms fn dictation hands whisper as a prompt.
/// A plain text editor, since the text — comments included — is what is stored.
struct DictationDictionarySection: View {
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var transcriptionEngine: TranscriptionEngine

    /// A draft until Save; `savedText` is what the store holds.
    @State private var text = DictationDictionary.text
    @State private var savedText = DictationDictionary.text
    @State private var saveFailed = false
    @State private var enabled = DictationDictionary.isEnabled
    @StateObject private var fit = PromptFitCounter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("dictation.dictionary.enabled".localized, isOn: $enabled)
                .onChange(of: enabled) { DictationDictionary.isEnabled = $0 }

            // Full width, unlike the pickers' 360 pt cap: an editor wraps its
            // lines and cannot push the sidebar.
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 240, maxHeight: 320)
                .border(Color.secondary.opacity(0.3))
                .onChange(of: text) { _ in
                    saveFailed = false
                    scheduleFit()
                }

            Text(countLabel)
                .font(.caption)
                .foregroundColor(isTrimmed ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let model = modelManager.activeModel, !model.supportsPrompt {
                Text("dictation.dictionary.unsupported".localized(with: model.name))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("dictation.dictionary.save".localized, action: save)
                    .keyboardShortcut("s")
                    .disabled(!hasChanges)
                saveStatus
            }

            HStack(spacing: 8) {
                Button("dictation.dictionary.import".localized, action: importFile)
                Button("dictation.dictionary.export".localized, action: exportFile)
                Button("dictation.dictionary.reset".localized, action: resetToExample)
                    .disabled(text == DictationDictionary.exampleText)
            }

            Text("dictation.dictionary.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .onAppear {
            text = DictationDictionary.text
            savedText = text
            enabled = DictationDictionary.isEnabled
            scheduleFit()
        }
        // Switching tabs or closing the window must not quietly drop the edits.
        .onDisappear { if hasChanges { DictationDictionary.save(text) } }
    }

    private var hasChanges: Bool { text != savedText }

    @ViewBuilder
    private var saveStatus: some View {
        Group {
            if saveFailed {
                Label("dictation.dictionary.saveFailed".localized, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            } else if hasChanges {
                Label("dictation.dictionary.unsaved".localized, systemImage: "pencil.circle")
                    .foregroundColor(.orange)
            } else {
                Label("dictation.dictionary.saved".localized, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .font(.caption)
    }

    private func save() {
        if DictationDictionary.save(text) {
            savedText = text
            saveFailed = false
        } else {
            saveFailed = true
            flog("DictationDictionary: save did not read back")
        }
    }

    private var terms: [String] { DictationDictionary.terms(from: text) }

    private var isTrimmed: Bool {
        fit.used.map { $0 < terms.count } ?? false
    }

    private var countLabel: String {
        if let used = fit.used, used < terms.count {
            return "vocab.fit".localized(with: used, terms.count)
        }
        return "vocab.count".localized(with: terms.count)
    }

    private func scheduleFit() {
        guard modelManager.activeModel?.supportsPrompt != false else { return fit.reset() }
        fit.schedule(terms: terms, engine: transcriptionEngine, maxTokens: DictationDictionary.maxTokens)
    }

    // MARK: - Actions

    /// Text the user wrote would be lost to an import or a reset; the example would not.
    private func confirmReplace() -> Bool {
        guard text != DictationDictionary.exampleText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "dictation.dictionary.replace.title".localized
        alert.informativeText = "dictation.dictionary.replace.message".localized
        alert.addButton(withTitle: "dictation.dictionary.replace.confirm".localized)
        alert.addButton(withTitle: "common.cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try String(contentsOf: url, encoding: .utf8)
            guard confirmReplace() else { return }
            text = imported
        } catch {
            flog("DictationDictionary: could not read \(url.path): \(error)")
            NSSound.beep()
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "dictation.dictionary.fileName".localized + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            flog("DictationDictionary: could not write \(url.path): \(error)")
            NSSound.beep()
        }
    }

    private func resetToExample() {
        guard confirmReplace() else { return }
        text = DictationDictionary.exampleText
    }
}
