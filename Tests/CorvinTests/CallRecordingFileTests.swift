import AudioToolbox
import AVFoundation
import XCTest
@testable import Corvin

/// The call file round trip without audio devices: writer → PCM parts → merged
/// AAC → per-channel decode.
final class CallRecordingFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `seconds` of a tone on the left and silence on the right, in 100 ms chunks.
    private func record(_ seconds: Double, base: String, chunkDuration: TimeInterval) throws -> CallTimelineWriter {
        let writer = try CallTimelineWriter(directory: directory, base: base, chunkDuration: chunkDuration)
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let tone = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let silence = [Float](repeating: 0, count: 1600)
        for chunk in 0..<Int(seconds * 10) {
            let hostTime = AVAudioTime.hostTime(forSeconds: origin + Double(chunk) * 0.1)
            writer.append(tone, hostTime: hostTime, channel: .me)
            writer.append(silence, hostTime: hostTime, channel: .other)
        }
        return writer
    }

    func testWriterAndDecoderKeepTheChannelsApart() throws {
        let writer = try record(2, base: "call", chunkDuration: 60)

        XCTAssertEqual(writer.finish(), 2.0, accuracy: 0.01)
        XCTAssertEqual(writer.parts.count, 1)

        let channels = try AudioFileDecoder.decodeChannels(url: writer.parts[0])
        XCTAssertEqual(Double(channels.left.count) / 2 / 16000, 2.0, accuracy: 0.05)
        XCTAssertEqual(channels.left.count, channels.right.count)
        XCTAssertTrue(AudioFileDecoder.isAudible(channels.left))
        XCTAssertFalse(AudioFileDecoder.isAudible(channels.right))
    }

    func testRecordingIsSplitIntoPartsThatAreClosedAsItGoes() throws {
        let writer = try record(2, base: "call", chunkDuration: 0.5)

        // Four half-second parts; the last one closes on finish().
        XCTAssertEqual(writer.parts.count, 4)
        XCTAssertEqual(writer.parts.map(CallRecordingParts.index(of:)), [1, 2, 3, 4])
        // Every part but the one in flight is complete on disk already.
        for part in writer.parts.dropLast() {
            let length = try AVAudioFile(forReading: part).length
            XCTAssertEqual(Double(length) / 16000, 0.5, accuracy: 0.01)
        }
        XCTAssertEqual(writer.finish(), 2.0, accuracy: 0.01)
    }

    func testPartsMergeIntoOneFile() throws {
        let writer = try record(2, base: "call", chunkDuration: 0.5)
        _ = writer.finish()
        let merged = directory.appendingPathComponent("merged.m4a")

        try CallRecorder.merge(writer.parts, to: merged)

        let channels = try AudioFileDecoder.decodeChannels(url: merged)
        XCTAssertEqual(Double(channels.left.count) / 2 / 16000, 2.0, accuracy: 0.2)
        XCTAssertTrue(AudioFileDecoder.isAudible(channels.left))
        XCTAssertFalse(AudioFileDecoder.isAudible(channels.right))
    }

    func testFinalizeMergesAndRemovesTheParts() throws {
        let writer = try record(1, base: "Call Telegram 2026-09-16 10-00", chunkDuration: 0.5)
        _ = writer.finish()
        let parts = writer.parts
        let calls = directory.appendingPathComponent("Calls", isDirectory: true)

        let outputs = CallRecorder.finalize(parts, preferredDirectory: calls)

        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].lastPathComponent, "Call Telegram 2026-09-16 10-00.m4a")
        XCTAssertEqual(outputs[0].deletingLastPathComponent().path, calls.path)
        for part in parts {
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        }
    }

    /// The merged file has to *be* an MPEG-4 file, not just be named like one.
    /// QuickTime and Finder go by the name and refuse anything else; reading it
    /// back with `AVAudioFile` sniffs the content and succeeds either way, which
    /// is how a CAF named .m4a got past every other test.
    func testMergedRecordingIsARealMPEG4File() throws {
        let writer = try record(1, base: "Call Telegram 2026-09-16 10-00", chunkDuration: 0.5)
        _ = writer.finish()

        let outputs = CallRecorder.finalize(writer.parts,
                                            preferredDirectory: directory.appendingPathComponent("Calls"))

        XCTAssertEqual(outputs.count, 1)
        let type = try containerType(outputs[0])
        XCTAssertTrue(type == kAudioFileM4AType || type == kAudioFileMPEG4Type,
                      "container is '\(fourCC(type))', not MPEG-4")
    }

    /// What the file's content says it is, whatever its name says.
    private func containerType(_ url: URL) throws -> AudioFileTypeID {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else {
            throw CallRecordingError.captureFailed("cannot open \(url.lastPathComponent)")
        }
        defer { AudioFileClose(file) }
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &type)
        return type
    }

    private func fourCC(_ code: UInt32) -> String {
        String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) })
    }

    func testLateChannelStartsWithSilence() throws {
        let writer = try CallTimelineWriter(directory: directory, base: "late", chunkDuration: 60)
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let tone = [Float](repeating: 0.5, count: 1600)
        for chunk in 0..<10 {
            writer.append(tone, hostTime: AVAudioTime.hostTime(forSeconds: origin + Double(chunk) * 0.1), channel: .me)
        }
        // The other side joins half a second in.
        for chunk in 5..<10 {
            writer.append(tone, hostTime: AVAudioTime.hostTime(forSeconds: origin + Double(chunk) * 0.1), channel: .other)
        }
        XCTAssertEqual(writer.finish(), 1.0, accuracy: 0.01)

        let right = try AudioFileDecoder.decodeChannels(url: writer.parts[0]).right
        let firstHalf = right.prefix(right.count / 2 - 1600)
        XCTAssertFalse(AudioFileDecoder.isAudible(Data(firstHalf)))
        XCTAssertTrue(AudioFileDecoder.isAudible(right))
    }

    /// Voice processing hands out several discrete channels; taking the first
    /// one must not become an average of whatever else is in there.
    func testMixdownPicksTheFirstChannelOrAveragesThem() throws {
        // Four discrete channels: the standard initializer stops at two.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        let data = buffer.floatChannelData!
        for frame in 0..<1600 {
            data[0][frame] = 0.4
            for channel in 1..<4 { data[channel][frame] = -0.4 }
        }

        let first = MonoResampler().convert(buffer, mixdown: .firstChannel)
        let averaged = MonoResampler().convert(buffer, mixdown: .average)

        XCTAssertEqual(first.dropFirst(200).first ?? 0, 0.4, accuracy: 0.02)
        XCTAssertEqual(averaged.dropFirst(200).first ?? 0, -0.2, accuracy: 0.02)
    }

    func testMonoFileIsRejectedForCallMode() throws {
        let url = directory.appendingPathComponent("mono.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            try file.write(from: buffer)
        }

        XCTAssertThrowsError(try AudioFileDecoder.decodeChannels(url: url))
    }
}

final class CallRecordingPartsTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/calls", isDirectory: true)

    func testPartNamesRoundTrip() {
        let url = CallRecordingParts.url(in: directory, base: "Call Zoom.us 2026-09-16 10-00", index: 7)

        XCTAssertEqual(url.lastPathComponent, "Call Zoom.us 2026-09-16 10-00.part7.caf")
        XCTAssertEqual(CallRecordingParts.base(of: url), "Call Zoom.us 2026-09-16 10-00")
        XCTAssertEqual(CallRecordingParts.index(of: url), 7)
    }

    func testGroupsPartsOfOneCallInOrder() {
        let urls = [10, 2, 1].map { CallRecordingParts.url(in: directory, base: "a", index: $0) }
            + [CallRecordingParts.url(in: directory, base: "b", index: 1)]

        let groups = CallRecordingParts.group(urls)

        XCTAssertEqual(groups.map(\.base), ["a", "b"])
        XCTAssertEqual(groups[0].parts.map(CallRecordingParts.index(of:)), [1, 2, 10])
    }

    func testFileWithoutPartSuffixIsItsOwnRecording() {
        let plain = directory.appendingPathComponent("Call Telegram.caf")

        XCTAssertEqual(CallRecordingParts.base(of: plain), "Call Telegram")
        XCTAssertEqual(CallRecordingParts.group([plain]).map(\.base), ["Call Telegram"])
    }

    func testNonRecordingFilesAreIgnored() {
        XCTAssertTrue(CallRecordingParts.group([directory.appendingPathComponent("notes.txt")]).isEmpty)
    }
}
