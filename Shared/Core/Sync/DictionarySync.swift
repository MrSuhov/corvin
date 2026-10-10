import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// Keeps the dictation dictionary the same on the user's own devices —
/// directly over the local network, never through a server.
///
/// Every paired device both advertises `_corvin-sync._tcp` and browses for it;
/// the TXT record names the group (`SyncPairing.groupID`), so someone else's
/// Corvin on the same Wi-Fi is ignored, and TLS with the group key as the
/// pre-shared key keeps everyone else out. An exchange is one round trip: the
/// caller sends its dictionary, the other side keeps the later save and sends
/// that back. It runs when a device appears, after a local save, and every few
/// minutes while one is in sight. Nothing listens until the device is paired.
final class DictionarySync: ObservableObject {
    static let shared = DictionarySync()

    static let serviceType = "_corvin-sync._tcp"
    private static let exchangeTimeout: TimeInterval = 10
    private static let backstopInterval: Int = 300
    private static let deviceIDKey = "dictionarySync.deviceID"
    private static let lastSyncKey = "dictionarySync.lastSync"

    struct LastSync: Codable, Equatable {
        let deviceName: String
        let date: Date
    }

    @Published private(set) var isPaired = false
    /// Devices of this group seen on the network right now.
    @Published private(set) var visiblePeerCount = 0
    @Published private(set) var lastSync: LastSync?

    /// Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "com.corvin.dictionary-sync")
    private var key: Data?
    private var groupID = ""
    private var deviceName = "Corvin"
    private let deviceID: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Device ID → where it listens.
    private var peers: [String: NWEndpoint] = [:]
    private var inFlight: Set<String> = []
    private var backstop: DispatchSourceTimer?

    private init() {
        let defaults = DictationDictionary.defaults
        if let id = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        lastSync = defaults.data(forKey: Self.lastSyncKey)
            .flatMap { try? JSONDecoder().decode(LastSync.self, from: $0) }
        DictationDictionary.onSave = { [weak self] in self?.syncNow() }
    }

    // MARK: - Control (main thread)

    /// Starts — or restarts, e.g. after iOS suspended the app and left the
    /// listener a zombie — if this device is paired.
    func start() {
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "Mac"
        #endif
        let key = SyncPairing.storedKey()
        isPaired = key != nil
        queue.async {
            self.deviceName = name
            self.restart(with: key)
        }
    }

    /// Joins the group from a scanned or pasted link.
    @discardableResult
    func pair(with invite: SyncPairing.Invite) -> Bool {
        guard SyncPairing.store(invite.key) else { return false }
        flog("DictionarySync: paired with \(invite.deviceName)")
        start()
        return true
    }

    /// The link for the QR code, making the group key on first use. `renew`
    /// makes a new one, which cuts off every device paired before.
    func invite(renew: Bool = false) -> SyncPairing.Invite? {
        if !renew, let key = SyncPairing.storedKey() {
            return SyncPairing.Invite(key: key, deviceName: currentDeviceName)
        }
        let key = SyncPairing.newKey()
        guard SyncPairing.store(key) else { return nil }
        setLastSync(nil)
        start()
        return SyncPairing.Invite(key: key, deviceName: currentDeviceName)
    }

    func unpair() {
        SyncPairing.deleteKey()
        isPaired = false
        setLastSync(nil)
        queue.async { self.restart(with: nil) }
        flog("DictionarySync: unpaired")
    }

    /// Exchanges with every device in sight.
    func syncNow() {
        queue.async {
            for (id, endpoint) in self.peers { self.exchange(with: id, at: endpoint) }
        }
    }

    private var currentDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    // MARK: - Network (queue)

    private func restart(with key: Data?) {
        listener?.cancel()
        browser?.cancel()
        backstop?.cancel()
        listener = nil
        browser = nil
        backstop = nil
        peers = [:]
        inFlight = []
        publishPeerCount()

        self.key = key
        guard let key else { return }
        groupID = SyncPairing.groupID(for: key)
        startListener()
        startBrowser()
        startBackstop()
    }

    private func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let psk = (key ?? Data()).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(groupID.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: parameters())
            listener.service = NWListener.Service(type: Self.serviceType,
                                                  txtRecord: NWTXTRecord(["g": groupID, "d": deviceID]))
            listener.newConnectionHandler = { [weak self] in self?.serve($0) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard case .failed(let error) = state else { return }
                flog("DictionarySync: listener failed: \(error)")
                self?.queue.asyncAfter(deadline: .now() + 5) {
                    guard let self, self.listener === listener else { return }
                    self.restart(with: self.key)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            flog("DictionarySync: listener not created: \(error)")
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { flog("DictionarySync: browser failed: \(error)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func startBackstop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Self.backstopInterval),
                       repeating: .seconds(Self.backstopInterval), leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for (id, endpoint) in self.peers { self.exchange(with: id, at: endpoint) }
        }
        timer.resume()
        backstop = timer
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [String: NWEndpoint] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  txt["g"] == groupID, let id = txt["d"], id != deviceID else { continue }
            found[id] = result.endpoint
        }
        let appeared = found.filter { peers[$0.key] == nil }
        peers = found
        publishPeerCount()
        for (id, endpoint) in appeared { exchange(with: id, at: endpoint) }
    }

    /// Caller side: send ours, keep whichever the other side says won.
    private func exchange(with id: String, at endpoint: NWEndpoint) {
        guard key != nil, inFlight.insert(id).inserted else { return }
        let connection = NWConnection(to: endpoint, using: parameters())
        var finished = false
        let finish: (String?) -> Void = { [weak self] failure in
            guard !finished else { return }
            finished = true
            connection.cancel()
            self?.inFlight.remove(id)
            if let failure { flog("DictionarySync: exchange failed: \(failure)") }
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else { return finish("gone") }
                self.send(DictationDictionary.state, on: connection) { error in
                    if let error { return finish("send: \(error)") }
                    self.receive(on: connection) { message in
                        guard let message else { return finish("no reply") }
                        self.apply(message)
                        finish(nil)
                    }
                }
            case .waiting(let error), .failed(let error):
                finish("\(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.exchangeTimeout) { finish("timeout") }
    }

    /// Listener side: take theirs if later, answer with what both should keep.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection) { [weak self] message in
            guard let self, let message else { return connection.cancel() }
            let kept = self.apply(message)
            self.send(kept, on: connection) { _ in connection.cancel() }
        }
        queue.asyncAfter(deadline: .now() + Self.exchangeTimeout) { connection.cancel() }
    }

    @discardableResult
    private func apply(_ message: SyncMessage) -> DictionaryState {
        let local = DictationDictionary.state
        let kept = SyncResolution.winner(local: local, remote: message.state)
        if kept != local {
            DictationDictionary.adopt(kept)
            flog("DictionarySync: took the dictionary from \(message.deviceName)")
        }
        setLastSync(LastSync(deviceName: message.deviceName, date: Date()))
        return kept
    }

    private func send(_ state: DictionaryState, on connection: NWConnection,
                      completion: @escaping (NWError?) -> Void) {
        let message = SyncMessage(text: state.text, savedAtMs: state.savedAtMs, deviceName: deviceName)
        guard let frame = try? SyncFraming.encode(message) else { return connection.cancel() }
        connection.send(content: frame, completion: .contentProcessed(completion))
    }

    private func receive(on connection: NWConnection, completion: @escaping (SyncMessage?) -> Void) {
        let header = SyncFraming.headerSize
        connection.receive(minimumIncompleteLength: header, maximumLength: header) { data, _, _, error in
            guard error == nil, let data, let length = SyncFraming.bodyLength(header: data) else {
                return completion(nil)
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body, body.count == length,
                      let message = try? SyncFraming.decode(body: body), message.version == 1
                else { return completion(nil) }
                completion(message)
            }
        }
    }

    // MARK: - Published state

    private func publishPeerCount() {
        let count = peers.count
        DispatchQueue.main.async { self.visiblePeerCount = count }
    }

    private func setLastSync(_ value: LastSync?) {
        let defaults = DictationDictionary.defaults
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.lastSyncKey)
        } else {
            defaults.removeObject(forKey: Self.lastSyncKey)
        }
        DispatchQueue.main.async { self.lastSync = value }
    }
}

extension DictionarySync {
    /// The status line under the dictionary on both platforms.
    var statusText: String {
        guard let last = lastSync else { return "dictation.sync.status.waiting".localized }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizedBundle.locale
        formatter.unitsStyle = .short
        let ago = formatter.localizedString(for: last.date, relativeTo: Date())
        return "dictation.sync.status.synced".localized(with: last.deviceName, ago)
    }
}
