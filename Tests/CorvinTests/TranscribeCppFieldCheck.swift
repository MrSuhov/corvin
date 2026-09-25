import XCTest
import CWhisper
@testable import Corvin

/// whisper.cpp and transcribe.cpp in one process, on real audio: each links a
/// ggml of its own, which is only safe while transcribe.cpp's stays inside its
/// dylib. Runs GigaAM, then whisper, then GigaAM again. Skipped unless pointed
/// at models and a short clip (≤ 1 min):
///
///     CORVIN_GIGAAM_MODEL=…/gigaam-v3-q8.gguf CORVIN_WHISPER_MODEL=…/ggml-small.bin \
///     CORVIN_CLIP=…/clip.wav swift test --filter TranscribeCppFieldCheck 2>&1 | grep -A20 "field check"
final class TranscribeCppFieldCheck: XCTestCase {

    func testWhisperAndGigaAMShareTheProcess() throws {
        let env = ProcessInfo.processInfo.environment
        guard let gigaamPath = env["CORVIN_GIGAAM_MODEL"], let whisperPath = env["CORVIN_WHISPER_MODEL"],
              let clip = env["CORVIN_CLIP"] else {
            throw XCTSkip("set CORVIN_GIGAAM_MODEL, CORVIN_WHISPER_MODEL and CORVIN_CLIP")
        }
        let pcm = try AudioFileDecoder.decode(url: URL(fileURLWithPath: clip))
        let samples = pcm.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        print("field check: \(clip), \(Double(samples.count) / 16000) s")

        let gigaam = try TranscribeCppModel(path: gigaamPath)
        let first = try gigaam.run(samples, language: nil, wordTimestamps: true, shouldAbort: { false })
        print("field check gigaam: \(first.text)")
        print("field check gigaam words: \(first.words.prefix(8).map { "\($0.text)@\(String(format: "%.2f", $0.start))" })")
        XCTAssertFalse(first.text.isEmpty)
        XCTAssertFalse(first.words.isEmpty)

        let ctx = try XCTUnwrap(whisper_init_from_file_with_params(whisperPath, whisper_context_default_params()))
        defer { whisper_free(ctx) }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        let status = samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        XCTAssertEqual(status, 0)
        let whisperText = (0..<whisper_full_n_segments(ctx))
            .compactMap { whisper_full_get_segment_text(ctx, $0).map { String(cString: $0) } }.joined()
        print("field check whisper: \(whisperText)")
        XCTAssertFalse(whisperText.isEmpty)

        let second = try gigaam.run(samples, language: nil, wordTimestamps: false, shouldAbort: { false })
        XCTAssertEqual(second.text, first.text, "GigaAM changed its answer after whisper ran")

        var calls = 0
        XCTAssertThrowsError(try gigaam.run(samples, language: nil, wordTimestamps: false,
                                            shouldAbort: { calls += 1; return true })) {
            XCTAssertTrue($0 is CancellationError, "abort should surface as CancellationError, got \($0)")
        }
    }
}
