import Foundation

/// What one device tells another: its dictionary and its name for the status line.
struct SyncMessage: Codable, Equatable {
    var version = 1
    let text: String
    let savedAtMs: Int64?
    let deviceName: String

    var state: DictionaryState { DictionaryState(text: text, savedAtMs: savedAtMs) }
}

/// 4-byte big-endian length, then JSON — the framing of the iOS keyboard IPC.
enum SyncFraming {
    /// A dictionary is a few kilobytes; anything near this is not one.
    static let maxBody = 256 * 1024
    static let headerSize = 4

    enum FramingError: Error { case tooLarge, truncated }

    static func encode(_ message: SyncMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maxBody else { throw FramingError.tooLarge }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: headerSize) + body
    }

    /// The body length a header announces; nil when it is not a sane frame.
    static func bodyLength(header: Data) -> Int? {
        guard header.count == headerSize else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        return length > 0 && length <= maxBody ? length : nil
    }

    static func decode(body: Data) throws -> SyncMessage {
        try JSONDecoder().decode(SyncMessage.self, from: body)
    }

    /// One whole frame from a buffer (tests and simple readers).
    static func decode(frame: Data) throws -> SyncMessage {
        let bytes = Data(frame)
        guard let length = bodyLength(header: bytes.prefix(headerSize)) else { throw FramingError.tooLarge }
        guard bytes.count >= headerSize + length else { throw FramingError.truncated }
        return try decode(body: bytes.dropFirst(headerSize).prefix(length))
    }
}
