import AppIntents

@available(iOS 16.0, *)
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Записать голос в Corvin"
    static var description = IntentDescription("Открывает Corvin для записи голоса")
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
            phrases: [
                "Запиши голос в \(.applicationName)",
                "Транскрипция в \(.applicationName)",
                "Record voice with \(.applicationName)",
            ],
            shortTitle: "Запись",
            systemImageName: "mic.fill"
        )
    }
}
