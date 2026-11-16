import AVFoundation
import XCTest
@testable import Corvin

/// `decode(url:)` reads AVFoundation formats block by block; the length and
/// the content have to survive the blocks and the resampling.
final class AudioFileDecoderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// An AAC `.m4a` of a 440 Hz tone, longer than one read block.
    private func writeTone(seconds: Double, rate: Double = 44100) throws -> URL {
        let url = directory.appendingPathComponent("tone.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) / rate * 440 * 2 * .pi)) * 0.5
        }
        try file.write(from: buffer)
        return url
    }

    func testDecodesAnAACFileAcrossBlocksAt16kHz() throws {
        let url = try writeTone(seconds: 3.5)

        let pcm = try AudioFileDecoder.decode(url: url)

        let seconds = Double(pcm.count / 2) / 16000
        XCTAssertEqual(seconds, 3.5, accuracy: 0.1)
        XCTAssertTrue(AudioFileDecoder.isAudible(pcm))
    }
}

/// Decodes a real file and reports how much of it could not be read — for a
/// file that fails in the app. Skipped unless pointed at one:
///
///     CORVIN_DECODE_FILE="$HOME/Downloads/<name>.mp4" swift test \
///         --filter AudioFileDecoderFieldCheck 2>&1 | grep "field check\|AudioFileDecoder"
final class AudioFileDecoderFieldCheck: XCTestCase {

    func testDecodesARealFile() throws {
        guard let path = ProcessInfo.processInfo.environment["CORVIN_DECODE_FILE"] else {
            throw XCTSkip("set CORVIN_DECODE_FILE to an audio file")
        }
        let pcm = try AudioFileDecoder.decode(url: URL(fileURLWithPath: path))
        print(String(format: "field check: %@ → %.1f s at 16 kHz", path, Double(pcm.count / 2) / 16000))
    }
}
