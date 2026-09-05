import AppIntents

@available(iOS 16.0, *)
struct StartRecordingIntent: AppIntent {
    // LocalizedStringResource resolves against Bundle.main's preferred
    // localization and cannot be pointed at the runtime-swapped bundle, so
    // these follow the *system* language rather than the in-app picker. That is
    // correct for a system surface — Siri and the Shortcuts app are not ours to
    // re-language — and is why they are keys here rather than `.localized`.
    static var title: LocalizedStringResource = "intent.record.title"
    static var description = IntentDescription("intent.record.description")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

@available(iOS 16.0, *)
struct CorvinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            // Spoken phrases are matched by Siri and cannot go through
            // `.localized` either. They are keyed by the English literal in
            // AppShortcuts.strings, one file per .lproj.
            phrases: [
                "Record voice with \(.applicationName)",
                "Transcribe with \(.applicationName)",
            ],
            shortTitle: "intent.record.shortTitle",
            systemImageName: "mic.fill"
        )
    }
}
