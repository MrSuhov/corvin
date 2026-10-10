import Foundation
import CryptoKit
import Security

/// The group key that lets the user's own devices sync the dictionary.
///
/// The Mac makes a random key and shows it as a `corvin://sync-pair` QR code;
/// the iPhone's camera opens it in Corvin. The key is the TLS pre-shared key,
/// so a device without it can neither connect nor read anything — and it never
/// leaves the devices except through that code on the user's own screen.
enum SyncPairing {
    static let keyLength = 32
    static let scheme = "corvin"
    static let host = "sync-pair"

    /// What a pairing link carries: the key and the name of the device that made it.
    struct Invite: Equatable, Identifiable {
        let key: Data
        let deviceName: String
        var id: Data { key }
    }

    static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Names the group on the network (Bonjour TXT, TLS identity) without
    /// revealing the key.
    static func groupID(for key: Data) -> String {
        SHA256.hash(data: Data("corvin-sync-group".utf8) + key)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Link

    static func url(for invite: Invite) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "k", value: base64URL(invite.key)),
            URLQueryItem(name: "n", value: invite.deviceName),
        ]
        return components.url!
    }

    static func invite(from url: URL) -> Invite? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let encoded = items.first(where: { $0.name == "k" })?.value,
              let key = data(base64URL: encoded), key.count == keyLength
        else { return nil }
        let name = items.first(where: { $0.name == "n" })?.value ?? ""
        return Invite(key: key, deviceName: name)
    }

    /// A link pasted as text, with stray whitespace around it.
    static func invite(from text: String) -> Invite? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(invite(from:))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - Keychain

    private static let service = "com.corvin.dictionary-sync"
    private static let account = "group-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func storedKey() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let key = result as? Data, key.count == keyLength else { return nil }
        return key
    }

    @discardableResult
    static func store(_ key: Data) -> Bool {
        deleteKey()
        var item = baseQuery
        item[kSecValueData as String] = key
        // The iOS app syncs from the background, with the phone locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { flog("DictionarySync: keychain add failed \(status)") }
        return status == errSecSuccess
    }

    static func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
