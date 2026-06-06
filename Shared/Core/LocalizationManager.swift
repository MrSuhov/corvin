import Foundation
import SwiftUI
import ObjectiveC

extension Notification.Name {
    /// Posted after the app UI language changes at runtime, so non-SwiftUI
    /// surfaces (e.g. AppKit NSMenu) can rebuild their localized titles.
    static let appLanguageChanged = Notification.Name("AppLanguageChanged")
}

// MARK: - Supported Languages

/// UI languages supported by the app
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "settings.language.useSystem".localized
        case .english:
            return "English"
        case .russian:
            return "Русский"
        }
    }
}

/// Keyboard languages for iOS keyboard extension
struct KeyboardLanguage: Identifiable, Hashable, Codable {
    let code: String
    let nameKey: String

    var id: String { code }

    var localizedName: String {
        nameKey.localized
    }

    static let all: [KeyboardLanguage] = [
        KeyboardLanguage(code: "en", nameKey: "keyboard.language.en"),
        KeyboardLanguage(code: "ru", nameKey: "keyboard.language.ru"),
        KeyboardLanguage(code: "uk", nameKey: "keyboard.language.uk"),
        KeyboardLanguage(code: "be", nameKey: "keyboard.language.be"),
        KeyboardLanguage(code: "pl", nameKey: "keyboard.language.pl"),
        KeyboardLanguage(code: "de", nameKey: "keyboard.language.de"),
        KeyboardLanguage(code: "fr", nameKey: "keyboard.language.fr"),
        KeyboardLanguage(code: "es", nameKey: "keyboard.language.es"),
        KeyboardLanguage(code: "it", nameKey: "keyboard.language.it"),
        KeyboardLanguage(code: "pt", nameKey: "keyboard.language.pt"),
        KeyboardLanguage(code: "cs", nameKey: "keyboard.language.cs"),
        KeyboardLanguage(code: "sk", nameKey: "keyboard.language.sk"),
        KeyboardLanguage(code: "hu", nameKey: "keyboard.language.hu"),
        KeyboardLanguage(code: "ro", nameKey: "keyboard.language.ro"),
        KeyboardLanguage(code: "bg", nameKey: "keyboard.language.bg"),
        KeyboardLanguage(code: "sr", nameKey: "keyboard.language.sr"),
        KeyboardLanguage(code: "hr", nameKey: "keyboard.language.hr"),
        KeyboardLanguage(code: "sl", nameKey: "keyboard.language.sl"),
        KeyboardLanguage(code: "lt", nameKey: "keyboard.language.lt"),
        KeyboardLanguage(code: "lv", nameKey: "keyboard.language.lv"),
        KeyboardLanguage(code: "et", nameKey: "keyboard.language.et"),
        KeyboardLanguage(code: "ka", nameKey: "keyboard.language.ka"),
        KeyboardLanguage(code: "hy", nameKey: "keyboard.language.hy"),
        KeyboardLanguage(code: "kk", nameKey: "keyboard.language.kk"),
        KeyboardLanguage(code: "az", nameKey: "keyboard.language.az"),
        KeyboardLanguage(code: "uz", nameKey: "keyboard.language.uz"),
        KeyboardLanguage(code: "tr", nameKey: "keyboard.language.tr"),
        KeyboardLanguage(code: "el", nameKey: "keyboard.language.el"),
        KeyboardLanguage(code: "nl", nameKey: "keyboard.language.nl"),
        KeyboardLanguage(code: "sv", nameKey: "keyboard.language.sv"),
        KeyboardLanguage(code: "da", nameKey: "keyboard.language.da"),
        KeyboardLanguage(code: "fi", nameKey: "keyboard.language.fi"),
        KeyboardLanguage(code: "nb", nameKey: "keyboard.language.nb"),
    ]

    /// Default enabled languages
    static let defaultEnabled: Set<String> = ["en", "ru"]
}

// MARK: - Localization Manager

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// Key for storing selected app language in UserDefaults
    private static let appLanguageKey = "appLanguage"
    /// Key for storing enabled keyboard languages in UserDefaults (legacy comma-separated format for keyboard extension)
    private static let keyboardLanguagesKey = "keyboardLanguages"

    /// Currently selected app language (empty string = system)
    @Published var currentLanguage: String {
        didSet {
            userDefaults.set(currentLanguage, forKey: Self.appLanguageKey)
            Bundle.setLanguage(currentLanguage)
            objectWillChange.send()
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }

    /// Enabled keyboard languages
    @Published var enabledKeyboardLanguages: Set<String> {
        didSet {
            // Save as comma-separated string for keyboard extension compatibility
            let ordered = KeyboardLanguage.all.map { $0.code }.filter { enabledKeyboardLanguages.contains($0) }
            userDefaults.set(ordered.joined(separator: ","), forKey: Self.keyboardLanguagesKey)
        }
    }

    private var userDefaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        return .standard
        #endif
    }

    private init() {
        // Use app group on iOS for sharing settings with keyboard extension
        #if os(iOS)
        let defaults = UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        let defaults = UserDefaults.standard
        #endif

        // Load saved language or use system default
        let savedLanguage = defaults.string(forKey: Self.appLanguageKey) ?? ""
        self.currentLanguage = savedLanguage

        // Load from comma-separated string format (keyboard extension compatible)
        if let savedString = defaults.string(forKey: Self.keyboardLanguagesKey), !savedString.isEmpty {
            let codes = savedString.split(separator: ",").map { String($0) }
            self.enabledKeyboardLanguages = Set(codes)
        } else {
            // First run: set defaults and save to UserDefaults
            self.enabledKeyboardLanguages = KeyboardLanguage.defaultEnabled
            // Manually save since didSet won't trigger in init
            let ordered = KeyboardLanguage.all.map { $0.code }.filter { KeyboardLanguage.defaultEnabled.contains($0) }
            defaults.set(ordered.joined(separator: ","), forKey: Self.keyboardLanguagesKey)
        }

        // Apply saved language on init
        if !savedLanguage.isEmpty {
            Bundle.setLanguage(savedLanguage)
        }
    }

    /// Set app language
    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language.rawValue
    }

    /// Get current AppLanguage enum value
    var appLanguage: AppLanguage {
        AppLanguage(rawValue: currentLanguage) ?? .system
    }

    /// Toggle keyboard language enabled state
    func toggleKeyboardLanguage(_ code: String) {
        if enabledKeyboardLanguages.contains(code) {
            // Don't allow disabling if it's the last one
            if enabledKeyboardLanguages.count > 1 {
                enabledKeyboardLanguages.remove(code)
            }
        } else {
            enabledKeyboardLanguages.insert(code)
        }
    }

    /// Check if keyboard language is enabled
    func isKeyboardLanguageEnabled(_ code: String) -> Bool {
        enabledKeyboardLanguages.contains(code)
    }

    /// Get list of enabled KeyboardLanguage objects
    var enabledKeyboardLanguagesList: [KeyboardLanguage] {
        KeyboardLanguage.all.filter { enabledKeyboardLanguages.contains($0.code) }
    }
}

// MARK: - Bundle Extension for Runtime Language Switching

private var bundleKey: UInt8 = 0

extension Bundle {
    /// Set the app's language at runtime
    static func setLanguage(_ language: String) {
        defer {
            // Reset cached bundle
            objc_setAssociatedObject(Bundle.main, &bundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        // Empty string means use system language
        guard !language.isEmpty else {
            objc_setAssociatedObject(Bundle.main, &bundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }

        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return
        }

        objc_setAssociatedObject(Bundle.main, &bundleKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Get the localized bundle (either custom or main)
    static var localizedBundle: Bundle {
        if let bundle = objc_getAssociatedObject(Bundle.main, &bundleKey) as? Bundle {
            return bundle
        }
        return Bundle.main
    }
}

// MARK: - String Extension for Localization

extension String {
    /// Returns the localized version of this string
    var localized: String {
        NSLocalizedString(self, bundle: Bundle.localizedBundle, comment: "")
    }

    /// Returns the localized version with arguments
    func localized(with arguments: CVarArg...) -> String {
        String(format: self.localized, arguments: arguments)
    }
}

// MARK: - SwiftUI Environment Support

private struct LocalizationManagerKey: EnvironmentKey {
    static let defaultValue = LocalizationManager.shared
}

extension EnvironmentValues {
    var localizationManager: LocalizationManager {
        get { self[LocalizationManagerKey.self] }
        set { self[LocalizationManagerKey.self] = newValue }
    }
}
