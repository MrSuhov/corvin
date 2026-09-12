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
/// action. Where they came from is deliberately not recorded: reading it needs
/// the private `_hostBundleID`, and a private call is not worth an automatic
/// trip back — the user returns by themselves.
enum HostAppWake {

    enum Outcome {
        case posted
        /// The user never granted notifications, so there is nothing we can show.
        case notAuthorized
        case failed
    }

    static func postWakeNotification(completion: @escaping (Outcome) -> Void) {
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
                    flog("HostAppWake: wake notification posted")
                    completion(.posted)
                }
            }
        }
    }
}
