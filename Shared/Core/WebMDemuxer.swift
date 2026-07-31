import Foundation

/// Minimal EBML/Matroska demuxer — just enough to pull the audio track out of a
/// WebM (or Matroska) file. Video tracks and everything else are skipped.
///
/// Handles unknown-size Segment/Cluster elements, which is what browser
/// `MediaRecorder` output looks like.
enum WebMDemuxer {

    struct AudioTrack {
        var number: UInt64 = 0
        var codecID: String = ""
        var codecPrivate: Data?
        var channels: Int = 1
        var sampleRate: Double = 48000
    }

    struct Result {
        let track: AudioTrack
        let packets: [Data]
    }

    enum DemuxError: LocalizedError {
        case notEBML
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .notEBML: return "Файл не является WebM/Matroska"
            case .noAudioTrack: return "В файле нет аудиодорожки"
            }
        }
    }

    // MARK: - Element IDs

    private enum ID {
        static let ebmlHeader: UInt32     = 0x1A45DFA3
        static let segment: UInt32        = 0x18538067
        static let seekHead: UInt32       = 0x114D9B74
        static let info: UInt32           = 0x1549A966
        static let tracks: UInt32         = 0x1654AE6B
        static let trackEntry: UInt32     = 0xAE
        static let trackNumber: UInt32    = 0xD7
        static let trackType: UInt32      = 0x83
        static let codecID: UInt32        = 0x86
        static let codecPrivate: UInt32   = 0x63A2
        static let audio: UInt32          = 0xE1
        static let channels: UInt32       = 0x9F
        static let samplingFreq: UInt32   = 0xB5
        static let cluster: UInt32        = 0x1F43B675
        static let timecode: UInt32       = 0xE7
        static let position: UInt32       = 0xA7
        static let prevSize: UInt32       = 0xAB
        static let simpleBlock: UInt32    = 0xA3
        static let blockGroup: UInt32     = 0xA0
        static let block: UInt32          = 0xA1
        static let encryptedBlock: UInt32 = 0xAF
        static let cues: UInt32           = 0x1C53BB6B
        static let chapters: UInt32       = 0x1043A770
        static let tags: UInt32           = 0x1254C367
        static let attachments: UInt32    = 0x1941A469
        static let void: UInt32           = 0xEC
        static let crc32: UInt32          = 0xBF
    }

    private static let mastersToDescend: Set<UInt32> = [
        ID.segment, ID.tracks, ID.trackEntry, ID.audio, ID.cluster, ID.blockGroup,
    ]

    // MARK: - Public entry point

    /// Parse a WebM/Matroska file and return the first audio track plus its
    /// encoded frames, in stream order.
    static func demux(data: Data) throws -> Result {
        let bytes = [UInt8](data)
        guard bytes.count >= 4,
              bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 else {
            throw DemuxError.notEBML
        }

        var ctx = Context()
        var pos = 0
        parse(bytes, &pos, end: bytes.count, parent: 0, parentUnknownSize: false, ctx: &ctx)

        guard let track = ctx.selectedTrack else { throw DemuxError.noAudioTrack }
        flog("WebMDemuxer: track #\(track.number) codec=\(track.codecID) ch=\(track.channels) packets=\(ctx.packets.count)")
        return Result(track: track, packets: ctx.packets)
    }

    // MARK: - Parsing

    private struct Context {
        var currentTrack: AudioTrack?
        var currentTrackType: UInt64 = 0
        var selectedTrack: AudioTrack?
        var packets: [Data] = []
    }

    private static func parse(_ b: [UInt8], _ pos: inout Int, end: Int, parent: UInt32,
                              parentUnknownSize: Bool, ctx: inout Context) {
        while pos < end {
            let elementStart = pos
            guard let id = readID(b, &pos) else { return }
            guard let (rawSize, unknownSize) = readSize(b, &pos) else { return }

            // Unknown-size elements only make sense for masters we can bound by
            // looking at what comes next.
            if unknownSize && !mastersToDescend.contains(id) { return }

            let contentStart = pos
            let available = UInt64(end - contentStart)
            if !unknownSize && rawSize > available {
                // Truncated file — consume what is there and stop.
                flog("WebMDemuxer: truncated element \(String(id, radix: 16)) at \(elementStart)")
            }
            let contentEnd = unknownSize ? end : contentStart + Int(min(rawSize, available))

            if mastersToDescend.contains(id) {
                if id == ID.trackEntry {
                    ctx.currentTrack = AudioTrack()
                    ctx.currentTrackType = 0
                }

                var childPos = contentStart
                parse(b, &childPos, end: contentEnd, parent: id, parentUnknownSize: unknownSize, ctx: &ctx)

                if id == ID.trackEntry {
                    if ctx.currentTrackType == 2, ctx.selectedTrack == nil, let t = ctx.currentTrack {
                        ctx.selectedTrack = t
                    }
                    ctx.currentTrack = nil
                }

                pos = unknownSize ? childPos : contentEnd
            } else {
                switch (parent, id) {
                case (ID.trackEntry, ID.trackNumber):
                    ctx.currentTrack?.number = readUInt(b, contentStart, contentEnd)
                case (ID.trackEntry, ID.trackType):
                    ctx.currentTrackType = readUInt(b, contentStart, contentEnd)
                case (ID.trackEntry, ID.codecID):
                    ctx.currentTrack?.codecID = readString(b, contentStart, contentEnd)
                case (ID.trackEntry, ID.codecPrivate):
                    ctx.currentTrack?.codecPrivate = Data(b[contentStart..<contentEnd])
                case (ID.audio, ID.channels):
                    ctx.currentTrack?.channels = max(1, Int(readUInt(b, contentStart, contentEnd)))
                case (ID.audio, ID.samplingFreq):
                    ctx.currentTrack?.sampleRate = readFloat(b, contentStart, contentEnd) ?? 48000
                case (ID.cluster, ID.simpleBlock), (ID.blockGroup, ID.block):
                    if let track = ctx.selectedTrack {
                        ctx.packets.append(contentsOf: frames(b, contentStart, contentEnd, trackNumber: track.number))
                    }
                default:
                    break
                }
                pos = contentEnd
            }

            // A zero-length read would spin forever.
            if pos <= elementStart { return }

            // For unknown-size masters we stop as soon as something that cannot
            // be our child shows up — that element belongs to our parent.
            if parentUnknownSize,
               unknownSizeParentShouldStop(parent: parent, next: b, at: pos, end: end) { return }
        }
    }

    /// Peek at the next element ID and decide whether it still belongs inside
    /// an unknown-size `parent`.
    private static func unknownSizeParentShouldStop(parent: UInt32, next b: [UInt8], at pos: Int, end: Int) -> Bool {
        guard parent == ID.segment || parent == ID.cluster else { return false }
        var peek = pos
        guard let id = readID(b, &peek), peek <= end else { return false }

        switch parent {
        case ID.segment:
            let allowed: Set<UInt32> = [ID.seekHead, ID.info, ID.tracks, ID.cluster, ID.cues,
                                        ID.chapters, ID.tags, ID.attachments, ID.void, ID.crc32]
            return !allowed.contains(id)
        case ID.cluster:
            let allowed: Set<UInt32> = [ID.timecode, ID.position, ID.prevSize, ID.simpleBlock,
                                        ID.blockGroup, ID.encryptedBlock, ID.void, ID.crc32]
            return !allowed.contains(id)
        default:
            return false
        }
    }

    // MARK: - Block payload

    /// Split a SimpleBlock/Block body into its encoded frames, honouring lacing.
    /// Returns an empty array for blocks belonging to another track.
    private static func frames(_ b: [UInt8], _ start: Int, _ end: Int, trackNumber: UInt64) -> [Data] {
        var p = start
        guard let (num, _) = readSize(b, &p), num == trackNumber else { return [] }
        guard p + 3 <= end else { return [] }
        p += 2 // relative timecode (int16)
        let flags = b[p]
        p += 1

        let lacing = (flags >> 1) & 0x03
        guard p <= end else { return [] }

        if lacing == 0 {
            guard p < end else { return [] }
            return [Data(b[p..<end])]
        }

        guard p < end else { return [] }
        let frameCount = Int(b[p]) + 1
        p += 1

        var sizes = [Int]()
        switch lacing {
        case 2: // fixed-size
            let total = end - p
            guard total > 0, total % frameCount == 0 else { return [] }
            sizes = Array(repeating: total / frameCount, count: frameCount - 1)
        case 1: // Xiph
            for _ in 0..<(frameCount - 1) {
                var size = 0
                while p < end {
                    let v = Int(b[p]); p += 1
                    size += v
                    if v != 255 { break }
                }
                sizes.append(size)
            }
        case 3: // EBML
            guard let (first, _) = readSize(b, &p) else { return [] }
            var prev = Int(first)
            sizes.append(prev)
            for _ in 0..<(frameCount - 2) {
                guard let (raw, len) = readSizeWithLength(b, &p) else { return [] }
                let bias = (1 << (7 * len - 1)) - 1
                prev += Int(raw) - bias
                guard prev >= 0 else { return [] }
                sizes.append(prev)
            }
        default:
            return []
        }

        var out = [Data]()
        out.reserveCapacity(frameCount)
        for size in sizes {
            guard size >= 0, p + size <= end else { return out }
            out.append(Data(b[p..<(p + size)]))
            p += size
        }
        if p < end { out.append(Data(b[p..<end])) }
        return out
    }

    // MARK: - Primitive readers

    private static func readID(_ b: [UInt8], _ p: inout Int) -> UInt32? {
        guard p < b.count else { return nil }
        let first = b[p]
        guard first != 0 else { return nil }
        var len = 1
        var mask: UInt8 = 0x80
        while (first & mask) == 0 { mask >>= 1; len += 1 }
        guard len <= 4, p + len <= b.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<len { v = (v << 8) | UInt32(b[p + i]) }
        p += len
        return v
    }

    /// Reads an EBML variable-length integer. Returns the value and whether all
    /// value bits were set (the "unknown size" marker).
    private static func readSize(_ b: [UInt8], _ p: inout Int) -> (UInt64, Bool)? {
        guard let (value, len) = readSizeWithLength(b, &p) else { return nil }
        let allOnes = value == (UInt64(1) << (7 * UInt64(len))) - 1
        return (value, allOnes)
    }

    /// Same as `readSize` but reports the encoded byte length instead — needed
    /// for EBML-lacing's signed deltas.
    private static func readSizeWithLength(_ b: [UInt8], _ p: inout Int) -> (UInt64, Int)? {
        guard p < b.count else { return nil }
        let first = b[p]
        guard first != 0 else { return nil }
        var len = 1
        var mask: UInt8 = 0x80
        while (first & mask) == 0 { mask >>= 1; len += 1 }
        guard len <= 8, p + len <= b.count else { return nil }
        var v = UInt64(first & (mask &- 1))
        for i in 1..<len { v = (v << 8) | UInt64(b[p + i]) }
        p += len
        return (v, len)
    }

    private static func readUInt(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in start..<min(end, start + 8) { v = (v << 8) | UInt64(b[i]) }
        return v
    }

    private static func readString(_ b: [UInt8], _ start: Int, _ end: Int) -> String {
        let raw = b[start..<end].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    private static func readFloat(_ b: [UInt8], _ start: Int, _ end: Int) -> Double? {
        switch end - start {
        case 4:
            var bits: UInt32 = 0
            for i in start..<end { bits = (bits << 8) | UInt32(b[i]) }
            return Double(Float(bitPattern: bits))
        case 8:
            var bits: UInt64 = 0
            for i in start..<end { bits = (bits << 8) | UInt64(b[i]) }
            return Double(bitPattern: bits)
        default:
            return nil
        }
    }
}
