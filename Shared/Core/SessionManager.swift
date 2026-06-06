import Foundation
import Combine

class SessionManager: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var recordingStartTime: Date?

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime, state == .recording else { return 0 }
        return Date().timeIntervalSince(start)
    }
}
