import SwiftUI
import UniformTypeIdentifiers

/// The dictation dictionary on iOS: terms every keyboard dictation hands
/// whisper as a prompt. Stored in the app group, where the host app reads it
/// for each transcription.
///
/// The text is a draft until Save: the settings list builds this view once, so
/// its initial state can be stale — the stored values are loaded on appear.
struct DictationDictionaryView: View {
    @EnvironmentObject var modelManager: ModelManager
    @ObservedObject private var sync = DictionarySync.shared

    @State private var text = ""
    /// What the store holds; the draft differs from it until Save.
    @State private var savedText = ""
    @State private var saveFailed = false
    @State private var enabled = DictationDictionary.isEnabled
    @State private var importing = false
    /// A file read but not applied yet: the user's own text is about to go.
    @State private var pendingImport: String?
    @State private var confirmingReset = false
    @State private var pairingInvite: SyncPairing.Invite?
    @State private var invalidLink = false

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
                    .onChange(of: text) { _ in saveFailed = false }
            } header: {
                saveStatus
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

            syncSection
        }
        .navigationTitle("dictation.dictionary.title".localized)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("dictation.dictionary.save".localized, action: save)
                    .disabled(!hasChanges)
            }
        }
        .onAppear {
            text = DictationDictionary.text
            savedText = text
            enabled = DictationDictionary.isEnabled
        }
        // Back is the system button; leaving must not quietly drop the edits.
        .onDisappear { if hasChanges { DictationDictionary.save(text) } }
        // Another device saved later: show its text, unless a draft is open —
        // then the draft stays and reads as unsaved against the new text.
        .onReceive(NotificationCenter.default.publisher(for: DictationDictionary.didChangeNotification)) { _ in
            let stored = DictationDictionary.text
            if !hasChanges { text = stored }
            savedText = stored
        }
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

    private var hasChanges: Bool { text != savedText }

    /// Pairing comes from the Mac's QR code (the camera opens it in Corvin);
    /// pasting the link is the way without a camera.
    private var syncSection: some View {
        Section {
            if sync.isPaired {
                Text(sync.statusText)
                    .foregroundColor(.secondary)
                Button("dictation.sync.unpair".localized, role: .destructive) { sync.unpair() }
            } else {
                Text("dictation.sync.pairIOS".localized)
                    .foregroundColor(.secondary)
                Button("dictation.sync.paste".localized) {
                    if let invite = UIPasteboard.general.string.flatMap(SyncPairing.invite(from:)) {
                        pairingInvite = invite
                    } else {
                        invalidLink = true
                    }
                }
            }
        } header: {
            Text("dictation.sync.title".localized)
        } footer: {
            Text("dictation.sync.hint".localized)
        }
        .alert("dictation.sync.invalidLink".localized, isPresented: $invalidLink) {
            Button("common.close".localized, role: .cancel) {}
        }
        .syncPairingConfirmation(invite: $pairingInvite)
    }

    @ViewBuilder
    private var saveStatus: some View {
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

    private func save() {
        if DictationDictionary.save(text) {
            savedText = text
            saveFailed = false
        } else {
            saveFailed = true
            flog("DictationDictionary: save did not read back")
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Text the user wrote would be lost to an import or a reset; the example would not.
    private var isUserText: Bool {
        text != DictationDictionary.exampleText
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
