import SwiftUI

struct iOSSettingsView: View {
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject var proManager = ProManager.shared
    @State private var showPaywall = false

    @AppStorage("autoCleanupPeriod", store: UserDefaults(suiteName: "group.com.corvinvoice.app"))
    private var autoCleanupPeriod: String = "never"

    var body: some View {
        NavigationView {
            Form {
                // Corvin Pro section — hidden unless the Pro experience is
                // enabled. Flip `AppFeatures.proEnabled` to restore it.
                if AppFeatures.proEnabled {
                Section(header: proSectionHeader) {
                    if proManager.isPro {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("pro.activated".localized)
                            Spacer()
                        }

                        // App icon picker
                        NavigationLink {
                            AppIconPickerView()
                        } label: {
                            HStack {
                                Text("settings.pro.appIcon".localized)
                                Spacer()
                            }
                        }
                    } else {
                        Button(action: { showPaywall = true }) {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.orange)
                                Text("settings.pro.learnMore".localized)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button("pro.restore".localized) {
                            proManager.triggerRestore()
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                }

                // App Language section
                Section(header: Text("settings.language.appLanguage".localized)) {
                    Picker(selection: $localization.currentLanguage, label: Text("settings.language.appLanguage".localized)) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                }

                // Keyboard Languages section
                Section(header: Text("settings.language.keyboardLanguages".localized)) {
                    NavigationLink {
                        KeyboardLanguagesView()
                    } label: {
                        HStack {
                            Text("settings.language.selectKeyboardLanguages".localized)
                            Spacer()
                            Text("\(localization.enabledKeyboardLanguages.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Auto-cleanup section
                Section(header: Text("settings.autoCleanup.header".localized)) {
                    Picker("settings.autoCleanup.period".localized, selection: $autoCleanupPeriod) {
                        Text("settings.autoCleanup.never".localized).tag("never")
                        Text("settings.autoCleanup.week".localized).tag("week")
                        Text("settings.autoCleanup.month".localized).tag("month")
                        Text("settings.autoCleanup.halfYear".localized).tag("halfYear")
                    }
                }

                // Diagnostics section
                Section(header: Text("settings.diagnostics.header".localized)) {
                    NavigationLink("settings.diagnostics.serverLogs".localized) {
                        LogView()
                    }
                }

                // About section
                Section(header: Text("settings.about.header".localized)) {
                    HStack {
                        Text("settings.about.version".localized)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("settings.about.transcription".localized)
                        Spacer()
                        Text("whisper.cpp (on-device)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("settings.title".localized)
            .sheet(isPresented: Binding(
                get: { AppFeatures.proEnabled && showPaywall },
                set: { showPaywall = $0 }
            )) {
                ProPaywallView()
            }
        }
    }

    private var proSectionHeader: some View {
        HStack(spacing: 4) {
            Text("settings.pro.title".localized)
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }
}

// MARK: - App Icon Picker (iOS only)

struct AppIconPickerView: View {
    @State private var currentIcon: String? = UIApplication.shared.alternateIconName

    var body: some View {
        List {
            iconRow(name: nil, displayName: "settings.pro.defaultIcon".localized)
            iconRow(name: "ProAppIcon", displayName: "settings.pro.proIcon".localized)
        }
        .navigationTitle("settings.pro.appIcon".localized)
    }

    private func iconRow(name: String?, displayName: String) -> some View {
        Button(action: {
            UIApplication.shared.setAlternateIconName(name) { error in
                if error == nil {
                    currentIcon = name
                }
            }
        }) {
            HStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(name == nil ? Color.blue : Color.orange)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: name == nil ? "mic.fill" : "star.fill")
                            .foregroundColor(.white)
                    )
                Text(displayName)
                Spacer()
                if currentIcon == name {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
