import UIKit
import UserNotifications

/// Getting the user into Corvin from the keyboard.
///
/// A keyboard extension cannot launch its containing app. That is not a gap to
/// work around: `extensionContext.open` is documented as supported only by the
/// Today and iMessage extension points, and Apple DTS has said in as many words
/// that walking the responder chain to call `openURL:` by selector is "not
/// allowed". Both were tried on device here and did nothing whatsoever — no
/// launch, no error. That code is gone.
///
/// What remains is to ask the user. A local notification is posted; tapping it
/// launches Corvin, terminated or not, because the tap is the user's own
/// action. The host's bundle id rides along in `userInfo` so the app can send
/// them back to where they were typing.
enum HostAppWake {

    /// Bundle id of the app the keyboard is open in. Private API: it lives on
    /// the extension context, and on some iOS versions only on the input view
    /// controller's parent, so both are tried. Probed with `responds(to:)`
    /// first — a rename must cost us the return trip, not a crash inside
    /// somebody else's text field.
    static func hostBundleID(of controller: UIInputViewController) -> String? {
        let selector = NSSelectorFromString("_hostBundleID")
        let candidates: [NSObject?] = [controller.extensionContext, controller.parent]
        for case let candidate? in candidates where candidate.responds(to: selector) {
            if let value = candidate.perform(selector)?.takeUnretainedValue() as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    enum Outcome {
        case posted
        /// The user never granted notifications, so there is nothing we can show.
        case notAuthorized
        case failed
    }

    static func postWakeNotification(host: String?, completion: @escaping (Outcome) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                flog("HostAppWake: notifications not authorized (status \(settings.authorizationStatus.rawValue))")
                completion(.notAuthorized)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "keyboard.wake.notification.title".localized
            content.body = "keyboard.wake.notification.body".localized
            content.categoryIdentifier = WakeNotification.category
            if let host, !host.isEmpty {
                content.userInfo = [WakeNotification.hostKey: host]
            }

            // nil trigger delivers immediately; a fresh id each time so a second
            // press is not swallowed as a duplicate of the first.
            let request = UNNotificationRequest(identifier: "\(WakeNotification.category).\(UUID().uuidString)",
                                                content: content,
                                                trigger: nil)
            center.add(request) { error in
                if let error {
                    flog("HostAppWake: could not post the wake notification: \(error.localizedDescription)")
                    completion(.failed)
                } else {
                    flog("HostAppWake: wake notification posted, host=\(host ?? "unknown")")
                    completion(.posted)
                }
            }
        }
    }
}
