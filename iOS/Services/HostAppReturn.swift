import UIKit

/// Sending the user back to the app they were typing in, after the keyboard
/// woke us with `corvin://wake?host=<bundle id>`.
///
/// iOS has no "return to whoever launched me" API, so the way back is an
/// ordinary URL-scheme open — which needs a table, because a bundle id is all
/// the keyboard can tell us. An app missing here, or one with no scheme at all,
/// simply gets no bounce: Corvin stays in the foreground and the user switches
/// back by hand. That is the honest failure mode, and it is why the trip back
/// is never promised in the UI before it happens.
enum HostAppReturn {

    static let scheme = "corvin"

    private static let returnSchemes: [String: String] = [
        "ph.telegra.Telegraph": "tg",
        "ru.keepcoder.Telegram": "tg",
        "net.whatsapp.WhatsApp": "whatsapp",
        "com.facebook.Messenger": "fb-messenger",
        "com.apple.MobileSMS": "sms",
        "com.apple.mobilemail": "message",
        "com.apple.mobilenotes": "mobilenotes",
        "com.tinyspeck.chatlyio": "slack",
        "com.hammerandchisel.discord": "discord",
        "com.google.Gmail": "googlegmail",
        "com.google.chrome.ios": "googlechrome",
        "com.microsoft.Office.Outlook": "ms-outlook",
        "com.burbn.instagram": "instagram",
        "com.atebits.Tweetie2": "twitter",
        "com.vk.vkclient": "vk",
        "com.viber": "viber",
        "com.linkedin.LinkedIn": "linkedin",
        "com.reddit.Reddit": "reddit",
    ]

    static func url(forHost bundleID: String?) -> URL? {
        guard let bundleID, let scheme = returnSchemes[bundleID] else { return nil }
        return URL(string: "\(scheme)://")
    }

    static func canReturn(to bundleID: String?) -> Bool {
        url(forHost: bundleID) != nil
    }

    /// `open` reports failure through its own result, so no `canOpenURL` probe
    /// is needed — and none is wanted: that one would need every scheme above
    /// declared in `LSApplicationQueriesSchemes`.
    @MainActor
    @discardableResult
    static func go(to bundleID: String?) async -> Bool {
        guard let url = url(forHost: bundleID) else { return false }
        return await UIApplication.shared.open(url)
    }
}
