import UIKit

/// Opening the containing app from the keyboard extension, and finding out
/// which app the keyboard is typing into.
///
/// Neither has a public API. `extensionContext.open(_:)` is documented as
/// Today-extension-only and does nothing here, and `UIApplication.shared` is
/// unavailable inside an extension; what is left is the responder chain, which
/// ends at the `UIApplication` of the keyboard's own process. The host app's
/// bundle id is carried by `_hostBundleID`, which is private.
///
/// Both are deliberate uses of API Apple does not offer to extensions, accepted
/// for the "wake Corvin" button. Every selector is probed with `responds(to:)`
/// first: if a future iOS renames one, the button has to stop working — never
/// crash the keyboard inside somebody else's text field.
enum HostAppLauncher {

    static let scheme = "corvin"

    /// `corvin://wake?host=<bundle id>` — the host id rides along so the app
    /// knows where to send the user back to.
    static func wakeURL(returningTo host: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "wake"
        if let host, !host.isEmpty {
            components.queryItems = [URLQueryItem(name: "host", value: host)]
        }
        return components.url
    }

    /// Bundle id of the app the keyboard is open in. Lives on the extension
    /// context, and on some iOS versions only on the input view controller's
    /// parent, so both are tried.
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

    /// Open the app. Two routes, tried in order.
    ///
    /// `extensionContext.open` is the sanctioned one: Apple documents it as
    /// working only for Today extensions, but it costs one call to find out,
    /// it reports its own success, and if a future iOS opens it up to keyboards
    /// this needs no further changes.
    ///
    /// Otherwise the responder chain. Note what is *not* checked here: that the
    /// responder is a `UIApplication`. Inside an extension the object that
    /// answers `openURL:` is usually some private proxy instead, so demanding
    /// the real class is how the first version of this silently did nothing.
    static func open(_ url: URL,
                     from controller: UIInputViewController,
                     completion: @escaping (Bool) -> Void) {
        guard let context = controller.extensionContext else {
            completion(openViaResponderChain(url, from: controller))
            return
        }
        context.open(url) { opened in
            if opened {
                flog("HostAppLauncher: opened via extensionContext")
                completion(true)
                return
            }
            flog("HostAppLauncher: extensionContext refused, trying the responder chain")
            completion(openViaResponderChain(url, from: controller))
        }
    }

    private static func openViaResponderChain(_ url: URL, from responder: UIResponder) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var next: UIResponder? = responder.next
        while let current = next {
            if current.responds(to: selector) {
                flog("HostAppLauncher: openURL: answered by \(type(of: current))")
                current.perform(selector, with: url)
                return true
            }
            next = current.next
        }
        flog("HostAppLauncher: nothing on the responder chain answered openURL:")
        return false
    }
}
