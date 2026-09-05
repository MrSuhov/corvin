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
    case spanish = "es"

    var id: String { rawValue }

    /// Language names stay in their own language — an endonym is what a speaker
    /// looks for in a picker, so these are deliberately not localized.
    var displayName: String {
        switch self {
        case .system:
            return "settings.language.useSystem".localized
        case .english:
            return "English"
        case .russian:
            return "Русский"
        case .spanish:
            return "Español"
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

    /// Both keys and the suite name live in `SharedDefaults` so the keyboard
    /// extension reads exactly what the app writes.
    private static let appLanguageKey = SharedDefaults.appLanguage
    private static let keyboardLanguagesKey = SharedDefaults.keyboardLanguages

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

    private var userDefaults: UserDefaults { Self.defaults }

    /// App Group on iOS so the keyboard extension sees the same values; plain
    /// standard defaults on macOS, which has no extension to share with.
    static var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: SharedDefaults.appGroup) ?? .standard
        #else
        return .standard
        #endif
    }

    private init() {
        let defaults = Self.defaults

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

// MARK: - Runtime Language Switching

/// Holds the bundle that `String.localized` resolves against.
///
/// This used to hang the bundle off `Bundle.main` with `objc_setAssociatedObject`,
/// and a `defer` block cleared it on *every* exit path — including the success
/// path, one instruction after it was set. The picker therefore never changed
/// anything, which is what the old "restart required" caption was papering over.
/// A plain holder is both correct and legible.
enum LocalizedBundle {
    private static let lock = NSLock()
    private static var _bundle: Bundle = .main
    private static var _locale: Locale = .current

    /// Bundle for string lookup. Falls back to `.main`, i.e. the system language.
    static var current: Bundle {
        lock.lock(); defer { lock.unlock() }
        return _bundle
    }

    /// Locale matching the chosen language, not the device's. Needed for
    /// `String(format:locale:)`: plural rules and the decimal separator have to
    /// follow the language on screen.
    static var locale: Locale {
        lock.lock(); defer { lock.unlock() }
        return _locale
    }

    /// - Parameter language: language code, or "" to follow the system.
    static func set(language: String) {
        lock.lock(); defer { lock.unlock() }

        guard !language.isEmpty else {
            _bundle = .main
            _locale = .current
            return
        }
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            // Silence here is how a mis-wired target looks: the picker appears to
            // work and changes nothing. Say so instead.
            flog("Localization: no \(language).lproj in \(Bundle.main.bundleIdentifier ?? "?") — language switch is a no-op")
            _bundle = .main
            _locale = .current
            return
        }
        _bundle = bundle
        _locale = Locale(identifier: language)
    }
}

extension Bundle {
    /// Kept as the call-site spelling used across the app and the keyboard extension.
    static func setLanguage(_ language: String) {
        LocalizedBundle.set(language: language)
    }
}

// MARK: - String Extension for Localization

extension String {
    /// Returns the localized version of this string
    var localized: String {
        let value = NSLocalizedString(self, bundle: LocalizedBundle.current, comment: "")
        #if DEBUG
        if value == self, self.contains(".") {
            flog("Localization: missing key '\(self)' in \(LocalizedBundle.current.bundlePath)")
        }
        #endif
        return value
    }

    /// Returns the localized version with arguments.
    ///
    /// The `locale:` argument is not optional in practice: without it `.stringsdict`
    /// plural templates are returned verbatim (`%#@count@` on screen), and `%f`
    /// renders with a POSIX decimal point in languages that use a comma.
    func localized(with arguments: CVarArg...) -> String {
        String(format: self.localized, locale: LocalizedBundle.locale, arguments: arguments)
    }
}

// MARK: - Deferred Messages

/// A message held as a key rather than as finished text.
///
/// Anything stored in view-model state outlives the language it was created in:
/// resolving at assignment time freezes an error banner in the old language for
/// as long as it stays on screen. Resolving in `text` at render time does not.
struct LocalizedMessage: Equatable {
    let key: String
    let args: [String]

    init(_ key: String, _ args: String...) {
        self.key = key
        self.args = args
    }

    var text: String {
        args.isEmpty
            ? key.localized
            : String(format: key.localized, locale: LocalizedBundle.locale, arguments: args)
    }
}
