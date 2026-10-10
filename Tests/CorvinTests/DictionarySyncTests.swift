import XCTest
@testable import Corvin

/// Dictionary sync without the network: who wins, the pairing link, the frame.
final class DictionarySyncTests: XCTestCase {

    override func tearDown() {
        for key in [DictationDictionary.textKey, DictationDictionary.savedAtKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Resolution

    func testLaterSaveWins() {
        let older = DictionaryState(text: "old", savedAtMs: 1_000)
        let newer = DictionaryState(text: "new", savedAtMs: 2_000)
        XCTAssertEqual(SyncResolution.winner(local: older, remote: newer), newer)
        XCTAssertEqual(SyncResolution.winner(local: newer, remote: older), newer)
    }

    /// A fresh device's example text must not overwrite a real dictionary.
    func testNeverSavedLoses() {
        let example = DictionaryState(text: "example", savedAtMs: nil)
        let saved = DictionaryState(text: "mine", savedAtMs: 1)
        XCTAssertEqual(SyncResolution.winner(local: example, remote: saved), saved)
        XCTAssertEqual(SyncResolution.winner(local: saved, remote: example), saved)
        XCTAssertEqual(SyncResolution.winner(local: example, remote: example), example)
    }

    /// Both sides pick the same text on a tie, whichever of them asks.
    func testTieIsResolvedTheSameWayOnBothSides() {
        let a = DictionaryState(text: "a", savedAtMs: 5)
        let b = DictionaryState(text: "b", savedAtMs: 5)
        XCTAssertEqual(SyncResolution.winner(local: a, remote: b), SyncResolution.winner(local: b, remote: a))
    }

    func testAdoptKeepsTheRemoteSaveTime() {
        DictationDictionary.save("local")
        DictationDictionary.adopt(DictionaryState(text: "remote", savedAtMs: 42))
        XCTAssertEqual(DictationDictionary.state, DictionaryState(text: "remote", savedAtMs: 42))
    }

    func testSaveStampsTime() {
        XCTAssertNil(DictationDictionary.savedAtMs)
        DictationDictionary.save("Корвин")
        XCTAssertNotNil(DictationDictionary.savedAtMs)
    }

    // MARK: - Pairing link

    func testLinkCarriesTheKey() throws {
        let invite = SyncPairing.Invite(key: SyncPairing.newKey(), deviceName: "Мой Mac")
        let url = SyncPairing.url(for: invite)
        XCTAssertEqual(url.scheme, "corvin")
        XCTAssertEqual(SyncPairing.invite(from: url), invite)
        XCTAssertEqual(SyncPairing.invite(from: "  \(url.absoluteString)\n"), invite)
    }

    func testBadLinksAreRejected() {
        XCTAssertNil(SyncPairing.invite(from: "corvin://sync-pair?k=c2hvcnQ"))  // 5 bytes
        XCTAssertNil(SyncPairing.invite(from: "https://example.com/sync-pair?k=AAAA"))
        XCTAssertNil(SyncPairing.invite(from: "corvin://other?k=AAAA"))
        XCTAssertNil(SyncPairing.invite(from: "not a link"))
    }

    func testGroupIDIsStableAndHidesTheKey() {
        let key = SyncPairing.newKey()
        let id = SyncPairing.groupID(for: key)
        XCTAssertEqual(id, SyncPairing.groupID(for: key))
        XCTAssertEqual(id.count, 16)
        XCTAssertNotEqual(id, SyncPairing.groupID(for: SyncPairing.newKey()))
        XCTAssertFalse(key.map { String(format: "%02x", $0) }.joined().contains(id))
    }

    // MARK: - Framing

    func testFrameRoundTrip() throws {
        let message = SyncMessage(text: "# note\nКорвин", savedAtMs: 1_733_000_000_123, deviceName: "iPhone")
        let frame = try SyncFraming.encode(message)
        XCTAssertEqual(try SyncFraming.decode(frame: frame), message)
    }

    func testTruncatedFrameFails() throws {
        let frame = try SyncFraming.encode(SyncMessage(text: "x", savedAtMs: 1, deviceName: "Mac"))
        XCTAssertThrowsError(try SyncFraming.decode(frame: frame.dropLast()))
    }

    func testOversizedFrameIsRefused() {
        let huge = SyncMessage(text: String(repeating: "a", count: SyncFraming.maxBody + 1),
                               savedAtMs: 1, deviceName: "Mac")
        XCTAssertThrowsError(try SyncFraming.encode(huge))
        XCTAssertNil(SyncFraming.bodyLength(header: Data([0x7f, 0xff, 0xff, 0xff])))
        XCTAssertNil(SyncFraming.bodyLength(header: Data([0, 0, 0, 0])))
    }
}
