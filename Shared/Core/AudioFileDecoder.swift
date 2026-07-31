import Foundation
import AVFoundation
import COpus

enum AudioFileDecoder {

    enum DecoderError: LocalizedError {
        case cannotOpenFile(String)
        case conversionFailed(String)
        case unsupportedCodec(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let path): return "Не удалось открыть файл: \(path)"
            case .conversionFailed(let reason): return "Ошибка конвертации: \(reason)"
            case .unsupportedCodec(let codec): return "Неподдерживаемый аудиокодек: \(codec)"
            case .emptyResult: return "Файл не содержит аудиоданных"
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

    /// 48kHz mono float → 16kHz mono Int16 (decimate by 3).
    private static func downsample48kToPCM16k(_ samples: [Float]) -> Data {
        let step = 3
        var pcmData = Data()
        pcmData.reserveCapacity(samples.count / step * MemoryLayout<Int16>.size)

        for i in stride(from: 0, to: samples.count, by: step) {
            let clamped = max(-1.0, min(1.0, samples[i]))
            var sample = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &sample) { pcmData.append(contentsOf: $0) }
        }
        return pcmData
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

        let frameCount = AVAudioFrameCount(file.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw DecoderError.conversionFailed("Cannot create source buffer")
        }
        try file.read(into: srcBuffer)

        let ratio = 16000.0 / srcFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputFrames) else {
            throw DecoderError.conversionFailed("Cannot create destination buffer")
        }

        var error: NSError?
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if let error = error {
            throw DecoderError.conversionFailed(error.localizedDescription)
        }

        guard dstBuffer.frameLength > 0 else {
            throw DecoderError.emptyResult
        }

        let byteCount = Int(dstBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: dstBuffer.int16ChannelData![0], count: byteCount)
    }

    // MARK: - Container sniffing

    /// Read the first bytes and detect the real container format by magic bytes.
    /// Returns a file extension AVAudioFile understands, or nil if unknown.
    private static func sniffFormat(url: URL) -> String? {
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
