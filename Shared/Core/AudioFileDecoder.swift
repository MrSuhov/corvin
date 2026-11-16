import Foundation
import Accelerate
import AVFoundation
import COpus

enum AudioFileDecoder {

    /// Extensions `decode(url:)` can actually handle. Single source of truth for
    /// the open panel's filter, the drag-and-drop filter, and the formats blurb —
    /// these used to be three hand-maintained lists that disagreed with each other
    /// and with the decoder.
    static let supportedExtensions: Set<String> = [
        // Opus containers (Telegram voice messages)
        "ogg", "opus", "oga",
        // Matroska / WebM
        "webm", "weba", "mkv", "mka",
        // Everything AVFoundation handles
        "wav", "m4a", "m4b", "mp4", "mp3", "aiff", "aif", "aifc", "flac", "caf",
    ]

    enum DecoderError: LocalizedError {
        case cannotOpenFile(String)
        case conversionFailed(String)
        case unsupportedCodec(String)
        case emptyResult
        case fileTooLarge(String)
        case notTwoChannels

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let path): return "decoder.cannotOpen".localized(with: path)
            case .conversionFailed(let reason): return "decoder.conversionFailed".localized(with: reason)
            case .unsupportedCodec(let codec): return "decoder.unsupportedCodec".localized(with: codec)
            case .emptyResult: return "decoder.emptyResult".localized
            case .fileTooLarge(let name): return "decoder.fileTooLarge".localized(with: name)
            case .notTwoChannels: return "decoder.notTwoChannels".localized
            }
        }
    }

    /// Decode OGG Opus file to 16kHz Int16 mono PCM Data.
    /// Uses libopusfile which always decodes to 48kHz — we then downsample to 16kHz.
    static func decodeOggOpus(url: URL) throws -> Data {
        flog("decodeOggOpus: opening \(url.lastPathComponent)")

        // Read file into memory first (sandbox-safe — Swift has access, C fopen may not)
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            flog("decodeOggOpus: FAILED to read file: \(error)")
            throw DecoderError.cannotOpenFile(error.localizedDescription)
        }
        flog("decodeOggOpus: read \(fileData.count) bytes into memory")

        let opFile: OpaquePointer? = fileData.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return op_open_memory(ptr, fileData.count, nil)
        }
        guard let opFile = opFile else {
            flog("decodeOggOpus: FAILED to open from memory")
            throw DecoderError.cannotOpenFile(url.lastPathComponent)
        }
        defer { op_free(opFile) }

        let channels = op_channel_count(opFile, -1)
        let totalSamples = op_pcm_total(opFile, -1)
        flog("decodeOggOpus: channels=\(channels), totalPCM=\(totalSamples) (~\(String(format: "%.1f", Double(totalSamples) / 48000.0))s at 48kHz)")

        // Read all PCM samples (48kHz float)
        var allSamples = [Float]()
        if totalSamples > 0 {
            allSamples.reserveCapacity(Int(totalSamples))
        }
        let bufSize = 5760 * 2 // max Opus frame * stereo
        var buf = [Float](repeating: 0, count: bufSize)

        while true {
            let read = op_read_float(opFile, &buf, Int32(bufSize / Int(channels)), nil)
            if read <= 0 { break }
            let frameCount = Int(read)

            if channels == 1 {
                allSamples.append(contentsOf: buf[0..<frameCount])
            } else {
                for i in 0..<frameCount {
                    let mono = (buf[i * 2] + buf[i * 2 + 1]) / 2.0
                    allSamples.append(mono)
                }
            }
        }

        flog("decodeOggOpus: decoded \(allSamples.count) samples at 48kHz")

        guard !allSamples.isEmpty else {
            throw DecoderError.emptyResult
        }

        let pcmData = downsample48kToPCM16k(allSamples)
        flog("decodeOggOpus: output \(pcmData.count) bytes (\(pcmData.count / 2) samples at 16kHz, ~\(String(format: "%.1f", Double(pcmData.count) / 2.0 / 16000.0))s)")
        return pcmData
    }

    /// Decode the audio track of a WebM/Matroska file to 16kHz Int16 mono PCM.
    /// Video tracks are ignored; only Opus audio is supported (the codec WebM
    /// audio is recorded with in practice).
    static func decodeWebM(url: URL) throws -> Data {
        flog("decodeWebM: opening \(url.lastPathComponent)")

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            flog("decodeWebM: FAILED to read file: \(error)")
            throw DecoderError.cannotOpenFile(error.localizedDescription)
        }
        flog("decodeWebM: read \(fileData.count) bytes into memory")

        let demuxed = try WebMDemuxer.demux(data: fileData)
        let track = demuxed.track

        guard track.codecID == "A_OPUS" else {
            flog("decodeWebM: unsupported codec \(track.codecID)")
            throw DecoderError.unsupportedCodec(track.codecID)
        }
        guard !demuxed.packets.isEmpty else { throw DecoderError.emptyResult }

        // OpusHead (RFC 7845 §5.1) lives in CodecPrivate.
        var channels = min(max(track.channels, 1), 2)
        var preSkip = 0
        if let head = track.codecPrivate, head.count >= 19,
           head.prefix(8).elementsEqual(Array("OpusHead".utf8)) {
            let h = [UInt8](head)
            channels = Int(h[9])
            preSkip = Int(h[10]) | (Int(h[11]) << 8)
            let mappingFamily = h[18]
            guard mappingFamily == 0 else {
                throw DecoderError.unsupportedCodec("Opus channel mapping family \(mappingFamily)")
            }
            guard channels == 1 || channels == 2 else {
                throw DecoderError.unsupportedCodec("Opus \(channels) channels")
            }
        }
        flog("decodeWebM: opus channels=\(channels), preSkip=\(preSkip), packets=\(demuxed.packets.count)")

        var err: Int32 = 0
        guard let decoder = opus_decoder_create(48000, Int32(channels), &err), err == OPUS_OK else {
            throw DecoderError.conversionFailed("opus_decoder_create failed (\(err))")
        }
        defer { opus_decoder_destroy(decoder) }

        // 5760 frames == 120ms at 48kHz, the largest Opus packet duration.
        let maxFrames = 5760
        var buf = [Float](repeating: 0, count: maxFrames * channels)
        var allSamples = [Float]()
        allSamples.reserveCapacity(demuxed.packets.count * 960)
        var failedPackets = 0

        for packet in demuxed.packets {
            let decoded: Int32 = packet.withUnsafeBytes { raw -> Int32 in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return opus_decode_float(decoder, ptr, Int32(packet.count), &buf, Int32(maxFrames), 0)
            }
            guard decoded > 0 else {
                failedPackets += 1
                continue
            }
            let frameCount = Int(decoded)
            if channels == 1 {
                allSamples.append(contentsOf: buf[0..<frameCount])
            } else {
                for i in 0..<frameCount {
                    allSamples.append((buf[i * 2] + buf[i * 2 + 1]) / 2.0)
                }
            }
        }

        if failedPackets > 0 {
            flog("decodeWebM: \(failedPackets) packet(s) failed to decode")
        }

        // Drop the encoder delay so the transcript is not preceded by garbage.
        if preSkip > 0 && preSkip < allSamples.count {
            allSamples.removeFirst(preSkip)
        }

        guard !allSamples.isEmpty else { throw DecoderError.emptyResult }
        flog("decodeWebM: decoded \(allSamples.count) samples at 48kHz")

        let pcmData = downsample48kToPCM16k(allSamples)
        flog("decodeWebM: output \(pcmData.count) bytes (\(pcmData.count / 2) samples at 16kHz, ~\(String(format: "%.1f", Double(pcmData.count) / 2.0 / 16000.0))s)")
        return pcmData
    }

    /// 48kHz mono float → 16kHz mono Int16.
    ///
    /// Low-pass before decimating: keeping every third sample on its own folds
    /// everything between 8 and 24 kHz back into the speech band. Whisper
    /// mostly shrugs that off; the speaker embeddings diarization compares
    /// voices with do not.
    private static func downsample48kToPCM16k(_ samples: [Float]) -> Data {
        let factor = 3
        let taps = lowPassTaps
        let half = taps.count / 2

        // Zero-pad by half the filter on both sides so it is centred on every
        // output sample: timing and length match the old plain decimation.
        var padded = [Float](repeating: 0, count: half)
        padded.reserveCapacity(samples.count + 2 * half)
        padded += samples
        padded += [Float](repeating: 0, count: half)

        let outCount = (samples.count + factor - 1) / factor
        var filtered = [Float](repeating: 0, count: outCount)
        vDSP_desamp(padded, vDSP_Stride(factor), taps, &filtered,
                    vDSP_Length(outCount), vDSP_Length(taps.count))

        let pcm = filtered.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
        return pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Windowed-sinc low-pass for 48 kHz input: cutoff 7.2 kHz, just under the
    /// 8 kHz Nyquist of the 16 kHz output. Blackman window, unity gain at DC.
    private static let lowPassTaps: [Float] = {
        let count = 97
        let cutoff = 7200.0 / 48000.0
        let mid = Double(count - 1) / 2
        let taps = (0..<count).map { n -> Double in
            let x = Double(n) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let phase = 2 * .pi * Double(n) / Double(count - 1)
            return sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
        }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }()

    /// Decode a two-channel recording into one 16 kHz Int16 mono track per
    /// channel. Corvin's call recordings put the microphone on the left and the
    /// other side on the right.
    ///
    /// Reads in one-second blocks, through `readTolerantly` like `decode(url:)`.
    static func decodeChannels(url: URL) throws -> (left: Data, right: Data) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecoderError.cannotOpenFile(error.localizedDescription)
        }
        // `processingFormat` is always deinterleaved Float32.
        let source = file.processingFormat
        guard source.channelCount == 2 else { throw DecoderError.notTwoChannels }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                       channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                         channels: 1, interleaved: true),
              let block = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(source.sampleRate)),
              let leftConverter = AVAudioConverter(from: mono, to: target),
              let rightConverter = AVAudioConverter(from: mono, to: target)
        else {
            throw DecoderError.conversionFailed("Cannot create formats for \(source)")
        }
        let converters = [leftConverter, rightConverter]
        var output = [Data(), Data()]

        /// `input == nil` flushes the converter at the end of the file.
        func convert(_ channel: Int, _ input: AVAudioPCMBuffer?) throws {
            let frames = Double(input?.frameLength ?? 0)
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(frames * 16000 / source.sampleRate) + 1024
            ) else {
                throw DecoderError.conversionFailed("Cannot create destination buffer")
            }
            var fed = false
            var error: NSError?
            converters[channel].convert(to: converted, error: &error) { _, status in
                guard let input else {
                    status.pointee = .endOfStream
                    return nil
                }
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw DecoderError.conversionFailed(error.localizedDescription) }
            output[channel].append(Data(bytes: converted.int16ChannelData![0],
                                        count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        }

        try readTolerantly(file, into: block) { block in
            let frames = Int(block.frameLength)
            for channel in 0..<2 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else {
                    throw DecoderError.conversionFailed("Cannot create channel buffer")
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                buffer.floatChannelData![0].update(from: block.floatChannelData![channel], count: frames)
                try convert(channel, buffer)
            }
        }
        for channel in 0..<2 { try convert(channel, nil) }

        guard !output[0].isEmpty else { throw DecoderError.emptyResult }
        return (output[0], output[1])
    }

    /// Whether 16 kHz Int16 audio holds anything above the noise floor.
    static func isAudible(_ pcm: Data, threshold: Int16 = 100) -> Bool {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).contains { $0 > threshold || $0 < -threshold }
        }
    }

    /// Decode any supported audio format to 16kHz Int16 mono PCM Data.
    static func decode(url: URL) throws -> Data {
        let ext = url.pathExtension.lowercased()
        let sniffed = sniffFormat(url: url)

        // OGG Opus requires special decoder (AVAudioFile doesn't support it).
        // Trust magic bytes over the extension — Telegram files often lie.
        if sniffed == "ogg" || ext == "ogg" || ext == "opus" || ext == "oga" {
            return try decodeOggOpus(url: url)
        }

        // WebM/Matroska — AVAudioFile has no idea what these are either.
        if sniffed == "webm" || ext == "webm" || ext == "weba" || ext == "mkv" || ext == "mka" {
            return try decodeWebM(url: url)
        }

        // If the extension disagrees with the actual container, AVAudioFile's
        // extension-based dispatch fails with kAudioFileInvalidFileError ('dta?').
        // Create a temp alias with the correct extension.
        let (effectiveURL, tempAlias) = normalizedURLForAVAudioFile(url: url, origExt: ext, realExt: sniffed)
        defer {
            if let tempAlias { try? FileManager.default.removeItem(at: tempAlias) }
        }

        // All other formats via AVAudioFile
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: effectiveURL)
        } catch {
            throw DecoderError.cannotOpenFile(error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw DecoderError.conversionFailed("Cannot create target format")
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw DecoderError.conversionFailed("Cannot create converter from \(srcFormat) to \(dstFormat)")
        }

        // One second at a time: a meeting runs for an hour, and one buffer for
        // the whole file at its source rate is gigabytes of Float32.
        guard let block = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(srcFormat.sampleRate)) else {
            throw DecoderError.conversionFailed("Cannot create source buffer")
        }
        var output = Data()

        /// `input == nil` flushes the converter at the end of the file.
        func convert(_ input: AVAudioPCMBuffer?) throws {
            let frames = Double(input?.frameLength ?? 0)
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: dstFormat,
                frameCapacity: AVAudioFrameCount(frames * 16000 / srcFormat.sampleRate) + 1024
            ) else {
                throw DecoderError.conversionFailed("Cannot create destination buffer")
            }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                guard let input else {
                    status.pointee = .endOfStream
                    return nil
                }
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw DecoderError.conversionFailed(error.localizedDescription) }
            output.append(Data(bytes: converted.int16ChannelData![0],
                               count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        }

        try readTolerantly(file, into: block) { try convert($0) }
        try convert(nil)

        guard !output.isEmpty else {
            throw DecoderError.emptyResult
        }
        return output
    }

    /// Reads `file` from start to end into `block`, handing each filled block
    /// to `consume`.
    ///
    /// Apple's AAC decoder rejects some packets that other decoders play: a
    /// 50-minute meeting `.mp4` failed at four spots (-50 from
    /// `ExtAudioFileRead`), three seconds in all, and one such spot used to fail
    /// the whole file. A block that will not decode becomes silence of the same
    /// length, and reading resumes one AAC packet further on at a time — so
    /// what follows keeps its true time. Up to a block of good audio around a
    /// bad spot is lost with it. Only a file nothing can be read from throws.
    private static func readTolerantly(
        _ file: AVAudioFile,
        into block: AVAudioPCMBuffer,
        _ consume: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        let packet: AVAudioFramePosition = 1024
        var decoded: AVAudioFramePosition = 0
        var skipped: AVAudioFramePosition = 0
        var firstError: Error?

        func silence(_ frames: AVAudioFramePosition) throws {
            guard let empty = AVAudioPCMBuffer(pcmFormat: block.format, frameCapacity: block.frameCapacity) else {
                throw DecoderError.conversionFailed("Cannot create silence buffer")
            }
            var left = frames
            while left > 0 {
                let count = AVAudioFrameCount(min(left, AVAudioFramePosition(empty.frameCapacity)))
                empty.frameLength = count
                for channel in 0..<Int(block.format.channelCount) {
                    empty.floatChannelData![channel].update(repeating: 0, count: Int(count))
                }
                try consume(empty)
                left -= AVAudioFramePosition(count)
            }
        }

        while file.framePosition < file.length {
            let start = file.framePosition
            do {
                try file.read(into: block)
            } catch {
                firstError = firstError ?? error
                var resume = start
                var readable = false
                while !readable {
                    resume += packet
                    guard resume < file.length else { break }
                    file.framePosition = resume
                    readable = (try? file.read(into: block)) != nil
                }
                resume = min(resume, file.length)
                flog("AudioFileDecoder: unreadable audio at \(Double(start) / file.processingFormat.sampleRate) s, "
                     + "\(Double(resume - start) / file.processingFormat.sampleRate) s replaced by silence: \(error)")
                skipped += resume - start
                try silence(resume - start)
                guard readable else { break }
            }
            guard block.frameLength > 0 else { break }
            decoded += AVAudioFramePosition(block.frameLength)
            try consume(block)
        }

        if decoded == 0, let firstError {
            throw DecoderError.conversionFailed(firstError.localizedDescription)
        }
        if skipped > 0 {
            flog("AudioFileDecoder: \(Double(skipped) / file.processingFormat.sampleRate) s of "
                 + "\(Double(file.length) / file.processingFormat.sampleRate) s could not be decoded")
        }
    }

    // MARK: - Container sniffing

    /// Read the first bytes and detect the real container format by magic bytes.
    /// Returns a file extension AVAudioFile understands, or nil if unknown.
    /// Best-effort container detection from magic bytes. Internal because the
    /// drop handler uses it as a second chance for files whose extension is
    /// missing or lying — the same reason this function exists at all.
    static func sniffFormat(url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16), data.count >= 4 else { return nil }
        let b = [UInt8](data)

        func match(_ at: Int, _ sig: [UInt8]) -> Bool {
            guard b.count >= at + sig.count else { return false }
            for i in 0..<sig.count where b[at + i] != sig[i] { return false }
            return true
        }

        // ISO BMFF (MP4/M4A/3GP/3GPP) — "ftyp" at offset 4
        if match(4, [0x66, 0x74, 0x79, 0x70]) { return "m4a" }
        // RIFF ... WAVE
        if match(0, [0x52, 0x49, 0x46, 0x46]) && match(8, [0x57, 0x41, 0x56, 0x45]) { return "wav" }
        // FORM ... AIFF / AIFC
        if match(0, [0x46, 0x4F, 0x52, 0x4D]) &&
           (match(8, [0x41, 0x49, 0x46, 0x46]) || match(8, [0x41, 0x49, 0x46, 0x43])) { return "aiff" }
        // fLaC
        if match(0, [0x66, 0x4C, 0x61, 0x43]) { return "flac" }
        // caff
        if match(0, [0x63, 0x61, 0x66, 0x66]) { return "caf" }
        // OggS
        if match(0, [0x4F, 0x67, 0x67, 0x53]) { return "ogg" }
        // EBML header — WebM / Matroska
        if match(0, [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        // ID3 tag (MP3)
        if match(0, [0x49, 0x44, 0x33]) { return "mp3" }
        // MPEG frame sync (0xFFEx) — raw MP3
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }
        return nil
    }

    /// If the extension lies about the container, produce a temp alias with the
    /// correct extension. Returns (urlToUse, tempAliasForCleanup-or-nil).
    private static func normalizedURLForAVAudioFile(url: URL, origExt: String, realExt: String?) -> (URL, URL?) {
        guard let real = realExt, real != origExt else { return (url, nil) }

        // Already a member of the same family — no alias needed.
        let m4aFamily: Set<String> = ["m4a", "m4b", "m4p", "mp4", "3gp", "3gpp", "mov", "caf"]
        if real == "m4a" && m4aFamily.contains(origExt) { return (url, nil) }

        let alias = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corvin-decode-\(UUID().uuidString).\(real)")

        // Prefer hard link (no copy, same inode). Fallback to full copy if the
        // temp dir is on a different volume or linking is denied.
        do {
            try FileManager.default.linkItem(at: url, to: alias)
            flog("AudioFileDecoder: ext '.\(origExt)' != real '.\(real)', hardlinked alias")
            return (alias, alias)
        } catch {
            do {
                try FileManager.default.copyItem(at: url, to: alias)
                flog("AudioFileDecoder: ext '.\(origExt)' != real '.\(real)', copied alias (link failed: \(error.localizedDescription))")
                return (alias, alias)
            } catch {
                flog("AudioFileDecoder: normalize ext failed: \(error)")
                return (url, nil)
            }
        }
    }
}
