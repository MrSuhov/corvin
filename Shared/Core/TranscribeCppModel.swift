import Foundation
#if canImport(CTranscribe)
import CTranscribe
#endif

extension ModelFamily {
    /// Whether this build carries the runtime for the family. A manifest entry
    /// of a family the build cannot run is dropped from the catalogue.
    var isSupported: Bool {
        switch self {
        case .whisper: return true
        case .gigaam:
            #if canImport(CTranscribe)
            return true
            #else
            return false
            #endif
        }
    }
}

/// Words from transcribe.cpp token rows. Pure, so it is tested without a model.
enum TranscribeCppWords {
    /// SentencePiece's word start: a token opening a word begins with it.
    static let wordMark = "\u{2581}"

    /// Punctuation tokens stay on the word before them, as whisper's do.
    static func words(from tokens: [(text: String, startMs: Int64, endMs: Int64)]) -> [TimedWord] {
        var words: [TimedWord] = []
        var current = ""
        var start: Int64 = 0
        var end: Int64 = 0
        func finish() {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                words.append(TimedWord(text: text, start: Double(start) / 1000, end: Double(end) / 1000))
            }
            current = ""
        }
        for token in tokens {
            var piece = token.text
            if piece.hasPrefix(wordMark) {
                finish()
                piece.removeFirst()
            }
            if current.isEmpty && piece.isEmpty { continue }
            if current.isEmpty { start = token.startMs }
            current += piece
            end = token.endMs
        }
        finish()
        return words
    }
}

#if canImport(CTranscribe)

/// A GGUF model run by transcribe.cpp — GigaAM today.
///
/// Not thread-safe: `TranscriptionEngine` calls it under `whisperLock`, which
/// also satisfies transcribe.cpp's rule of one run at a time per model.
final class TranscribeCppModel {
    private let model: OpaquePointer
    private let session: OpaquePointer
    /// The longest input one `run` accepts (25 s for GigaAM).
    let maxSamples: Int

    struct Output {
        let text: String
        /// Seconds from the start of the input.
        let words: [TimedWord]
    }

    enum Failure: Error {
        case load(String)
        case run(String)
    }

    init(path: String, useGPU: Bool = true) throws {
        Self.routeLogs
        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = useGPU ? TRANSCRIBE_BACKEND_AUTO : TRANSCRIBE_BACKEND_CPU

        var model: OpaquePointer?
        var status = transcribe_model_load_file(path, &loadParams, &model)
        guard status == TRANSCRIBE_OK, let model else {
            throw Failure.load(Self.describe(status))
        }

        var sessionParams = transcribe_session_params()
        transcribe_session_params_init(&sessionParams)
        sessionParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        var session: OpaquePointer?
        status = transcribe_session_init(model, &sessionParams, &session)
        guard status == TRANSCRIBE_OK, let session else {
            transcribe_model_free(model)
            throw Failure.load(Self.describe(status))
        }

        var limits = transcribe_session_limits()
        transcribe_session_limits_init(&limits)
        let maxMs = transcribe_session_get_limits(session, &limits) == TRANSCRIBE_OK
            ? limits.effective_max_audio_ms : 0
        self.model = model
        self.session = session
        // A whole second under the limit: the chunker cuts at silence *before*
        // its maximum, never after, but the margin costs nothing.
        self.maxSamples = maxMs > 0 ? Int(maxMs - 1000) * 16 : 24 * 16000
        flog("transcribe.cpp: loaded \(String(cString: transcribe_model_arch_string(model))) on \(String(cString: transcribe_model_backend(model))), max \(maxMs) ms")
    }

    deinit {
        transcribe_session_free(session)
        transcribe_model_free(model)
    }

    /// One pass over at most `maxSamples` of 16 kHz mono audio.
    ///
    /// - Parameter shouldAbort: polled by the library during the run; returning
    ///   true stops it and `run` throws `CancellationError`.
    func run(_ samples: [Float], language: String?, wordTimestamps: Bool,
             shouldAbort: @escaping () -> Bool) throws -> Output {
        let abort = AbortBox(shouldAbort)
        transcribe_set_abort_callback(session, { userData in
            guard let userData else { return false }
            return Unmanaged<AbortBox>.fromOpaque(userData).takeUnretainedValue().check()
        }, Unmanaged.passUnretained(abort).toOpaque())
        defer { transcribe_set_abort_callback(session, nil, nil) }

        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        // Token rows are what GigaAM times; words are assembled from them.
        params.timestamps = wordTimestamps ? TRANSCRIBE_TIMESTAMPS_TOKEN : TRANSCRIBE_TIMESTAMPS_NONE
        // pnc/itn stay at DEFAULT: the e2e model punctuates and writes numbers
        // as digits by itself, and asking for either explicitly only logs a
        // warning per chunk that it cannot be controlled.

        let status: transcribe_status = withExtendedLifetime(abort) {
            Self.withOptionalCString(language) { languagePtr in
                params.language = languagePtr
                return samples.withUnsafeBufferPointer { ptr in
                    transcribe_run(session, ptr.baseAddress, Int32(ptr.count), &params)
                }
            }
        }
        if status == TRANSCRIBE_ERR_ABORTED || transcribe_was_aborted(session) {
            throw CancellationError()
        }
        guard status == TRANSCRIBE_OK else { throw Failure.run(Self.describe(status)) }

        let text = transcribe_full_text(session).map { String(decoding: Self.bytes(of: $0), as: UTF8.self) } ?? ""
        return Output(text: text, words: wordTimestamps ? readWords() : [])
    }

    private func readWords() -> [TimedWord] {
        var tokens: [(text: String, startMs: Int64, endMs: Int64)] = []
        for i in 0..<transcribe_n_tokens(session) {
            var token = transcribe_token()
            transcribe_token_init(&token)
            guard transcribe_get_token(session, i, &token) == TRANSCRIBE_OK, let raw = token.text else { continue }
            tokens.append((String(decoding: Self.bytes(of: raw), as: UTF8.self), token.t0_ms, token.t1_ms))
        }
        return TranscribeCppWords.words(from: tokens)
    }

    // MARK: - Plumbing

    private final class AbortBox {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }

    /// Library and ggml messages into Corvin's log instead of stderr; once per
    /// process, before the first model loads, as the API requires.
    private static let routeLogs: Void = {
        transcribe_log_set({ level, message, _ in
            guard level == TRANSCRIBE_LOG_LEVEL_ERROR || level == TRANSCRIBE_LOG_LEVEL_WARN,
                  let message else { return }
            flog("transcribe.cpp: \(String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines))")
        }, nil)
    }()

    private static func describe(_ status: transcribe_status) -> String {
        transcribe_status_string(Int32(status.rawValue)).map { String(cString: $0) } ?? "status \(status.rawValue)"
    }

    private static func bytes(of cString: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self),
                                  count: strlen(cString)))
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
        guard let string else { return try body(nil) }
        return try string.withCString(body)
    }
}

#endif
