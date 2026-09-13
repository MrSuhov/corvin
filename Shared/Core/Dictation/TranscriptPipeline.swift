import Foundation

/// Consumer of transcript events: text insertion, clipboard, history — and
/// later an assistant that answers the utterance.
///
/// Sinks are called on the main thread in registration order. A sink that
/// talks to a service hands the work to a task of its own instead of blocking:
/// an assistant sink would react to `.finished`, start the request, and stream
/// the reply to its own presenter.
protocol TranscriptSink: AnyObject {
    func handle(_ event: TranscriptEvent)
}

/// Transforms the finished utterance before sinks see it — punctuation fixes,
/// translation, command expansion.
///
/// Processors only ever see the whole utterance. One that changes the text is
/// incompatible with realtime insertion: committed chunks are already typed into
/// the target app and cannot be taken back, so the coordinator falls back to
/// inserting on release whenever such a processor is registered.
protocol TranscriptProcessor {
    var modifiesText: Bool { get }
    func process(_ result: TranscriptionResult) async throws -> TranscriptionResult
}

final class TranscriptPipeline {
    private let processors: [TranscriptProcessor]
    private let sinks: [TranscriptSink]

    init(processors: [TranscriptProcessor] = [], sinks: [TranscriptSink]) {
        self.processors = processors
        self.sinks = sinks
    }

    var modifiesText: Bool {
        processors.contains { $0.modifiesText }
    }

    func process(_ result: TranscriptionResult) async throws -> TranscriptionResult {
        var current = result
        for processor in processors {
            current = try await processor.process(current)
        }
        return current
    }

    /// Call on the main thread.
    func send(_ event: TranscriptEvent) {
        for sink in sinks {
            sink.handle(event)
        }
    }
}
