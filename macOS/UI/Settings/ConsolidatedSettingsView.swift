import SwiftUI

/// Everything that is not Files or Models: one scrolling page
/// of sections instead of six sidebar tabs with a handful of controls each.
///
/// The sections are the existing panes, unchanged except for their root stack,
/// so every setting still has exactly one implementation.
struct ConsolidatedSettingsView: View {
    @ObservedObject private var localization = LocalizationManager.shared

    private static let gutter: CGFloat = 16

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("settings.tab.general".localized) { GeneralSettingsView() }
                section("settings.tab.language".localized) { LanguageSettingsView() }
                section("settings.tab.indicator".localized) { IndicatorSettingsView() }
                section("settings.tab.layout".localized) { LayoutSwitchSettingsView() }
                section("test.call.title".localized) { CallSettingsView() }
                section("settings.autoCleanup.header".localized) { CleanupSettingsView() }
                section("settings.tab.permissions".localized) { PermissionsSettingsView() }
            }
            .padding(.vertical, Self.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(localization.currentLanguage)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, Self.gutter)
            Divider()
                .padding(.horizontal, Self.gutter)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Call recording: the part length is its only setting; recording itself
/// starts from the menubar.
struct CallSettingsView: View {
    @AppStorage(CallSettings.chunkMinutesKey) private var chunkMinutes = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("test.call.chunk.label".localized)
                Stepper(value: $chunkMinutes, in: CallSettings.chunkRange) {
                    Text("\(chunkMinutes)")
                        .font(.system(.body, design: .monospaced))
                }
                .frame(maxWidth: 90)
            }
            Text("test.call.chunk.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}
