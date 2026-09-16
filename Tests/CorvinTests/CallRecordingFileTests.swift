import AVFoundation
import XCTest
@testable import Corvin

/// The call file round trip without audio devices: writer → CAF → AAC →
/// per-channel decode.
final class CallRecordingFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Two seconds of a tone on the left, silence on the right, in 100 ms chunks.
    private func recordTwoSeconds(to url: URL) throws -> TimeInterval {
        let writer = try CallTimelineWriter(url: url)
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let tone = (0..<1600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }
        let silence = [Float](repeating: 0, count: 1600)
        for chunk in 0..<20 {
            let hostTime = AVAudioTime.hostTime(forSeconds: origin + Double(chunk) * 0.1)
            writer.append(tone, hostTime: hostTime, channel: .me)
            writer.append(silence, hostTime: hostTime, channel: .other)
        }
        return writer.finish()
    }

    func testWriterAndDecoderKeepTheChannelsApart() throws {
        let caf = directory.appendingPathComponent("call.caf")

        XCTAssertEqual(try recordTwoSeconds(to: caf), 2.0, accuracy: 0.01)

        let channels = try AudioFileDecoder.decodeChannels(url: caf)
        XCTAssertEqual(Double(channels.left.count) / 2 / 16000, 2.0, accuracy: 0.05)
        XCTAssertEqual(channels.left.count, channels.right.count)
        XCTAssertTrue(AudioFileDecoder.isAudible(channels.left))
        XCTAssertFalse(AudioFileDecoder.isAudible(channels.right))
    }

    func testLateChannelStartsWithSilence() throws {
        let caf = directory.appendingPathComponent("late.caf")
        let writer = try CallTimelineWriter(url: caf)
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

        let right = try AudioFileDecoder.decodeChannels(url: caf).right
        let firstHalf = right.prefix(right.count / 2 - 1600)
        XCTAssertFalse(AudioFileDecoder.isAudible(Data(firstHalf)))
        XCTAssertTrue(AudioFileDecoder.isAudible(right))
    }

    func testConvertsToM4AAndDecodesBothChannels() throws {
        let caf = directory.appendingPathComponent("call.caf")
        let m4a = directory.appendingPathComponent("call.m4a")
        _ = try recordTwoSeconds(to: caf)

        try CallRecorder.convertToM4A(caf, to: m4a)

        let channels = try AudioFileDecoder.decodeChannels(url: m4a)
        XCTAssertEqual(Double(channels.left.count) / 2 / 16000, 2.0, accuracy: 0.2)
        XCTAssertTrue(AudioFileDecoder.isAudible(channels.left))
        XCTAssertFalse(AudioFileDecoder.isAudible(channels.right))
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
