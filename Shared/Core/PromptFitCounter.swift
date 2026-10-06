import Foundation
import Combine

/// How many of an editor's terms fit whisper's prompt, counted as the user
/// types. Only with a model already in memory: loading one just to count would
/// take seconds and gigabytes.
final class PromptFitCounter: ObservableObject {
    /// Terms that fit; nil until counted, or when there is nothing to count.
    @Published private(set) var used: Int?

    /// Bumped per request so a slow count for older text never overwrites a newer one.
    private var generation = 0

    func schedule(terms: [String], engine: TranscriptionEngine, maxTokens: Int) {
        generation += 1
        let current = generation
        guard engine.isModelLoaded, !terms.isEmpty else {
            used = nil
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let fitted = try? engine.fitPrompt(terms: terms, maxTokens: maxTokens) else { return }
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.used = fitted.used
            }
        }
    }

    func reset() {
        generation += 1
        used = nil
    }
}
