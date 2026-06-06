import Foundation

enum SessionState: Equatable {
    case idle
    case recording
    case transcribing
    case inserting(String)
    case done(String)
    case error(String)

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.transcribing, .transcribing):
            return true
        case let (.inserting(a), .inserting(b)):
            return a == b
        case let (.done(a), .done(b)):
            return a == b
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}
