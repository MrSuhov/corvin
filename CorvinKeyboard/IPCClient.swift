import Foundation

class IPCClient {
    private let maxRetries = 3
    private let retryDelay: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds

    /// Create fresh URLSession for each request batch
    /// This prevents issues with stale sessions after keyboard extension suspend/resume
    private func createSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5 // Shorter timeout for faster retry
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Execute request with retry logic
    /// Creates fresh URLSession for each call to handle suspend/resume scenarios
    private func executeWithRetry(
        request: URLRequest,
        operation: String
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 1...maxRetries {
            // Create fresh session for each attempt to avoid stale connection state
            let session = createSession()
            defer { session.invalidateAndCancel() }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.serverError("\(operation): invalid response")
                }
                return (data, http)
            } catch {
                lastError = error
                flog("IPC \(operation): attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription)")

                if attempt < maxRetries {
                    // Wait before retry
                    try? await Task.sleep(nanoseconds: retryDelay)
                }
            }
        }

        flog("IPC \(operation): all \(maxRetries) attempts failed")
        throw IPCError.connectionFailed
    }

    /// Presence signal for the host app. Single attempt, short timeout — this runs on
    /// every keyboard appearance and must not block the UI.
    ///
    /// Success also proves the host survived in the background, so it doubles as the
    /// health check: the keyboard extension has no way to launch the host app itself.
    @discardableResult
    func notifyKeyboard(active: Bool) async -> Bool {
        var request = URLRequest(url: active ? IPCConfig.keyboardActiveURL : IPCConfig.keyboardInactiveURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 2

        let session = createSession()
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            flog("IPC keyboard-\(active ? "active" : "inactive"): ok=\(ok)")
            return ok
        } catch {
            flog("IPC keyboard-\(active ? "active" : "inactive") failed: \(error.localizedDescription)")
            return false
        }
    }

    func startRecording() async throws {
        flog("IPC startRecording: connecting...")

        var request = URLRequest(url: IPCConfig.startRecordingURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        let (data, http) = try await executeWithRetry(request: request, operation: "startRecording")

        flog("IPC startRecording: status=\(http.statusCode)")

        // Parse error from JSON response
        if http.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["error"] as? String {
                flog("IPC startRecording: server error: \(errorMsg)")
                // The host is up but cannot record — recoverable by opening it.
                if json["code"] as? String == IPCErrorCode.hostNotReady {
                    throw IPCError.hostNotReady
                }
                throw IPCError.serverError(errorMsg)
            }
            throw IPCError.serverError("start-recording failed (\(http.statusCode))")
        }
        flog("IPC startRecording: success")
    }

    func stopRecordingAndTranscribe() async throws -> TranscriptionResult {
        flog("IPC stopRecording: connecting...")

        // POST /stop-recording → get request ID
        var request = URLRequest(url: IPCConfig.stopRecordingURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        let startTime = Date()
        let (data, http) = try await executeWithRetry(request: request, operation: "stopRecording")
        let elapsed = Date().timeIntervalSince(startTime)

        flog("IPC stopRecording: status=\(http.statusCode), elapsed=\(String(format: "%.2f", elapsed))s")

        let requestId: String
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            requestId = id
        } else {
            flog("IPC stopRecording: no id in response, data=\(String(data: data, encoding: .utf8) ?? "nil")")
            throw IPCError.serverError("stop-recording: no id in response")
        }

        flog("IPC stopRecording: got id=\(requestId.prefix(8))...")

        // Poll for result with connection error tolerance
        return try await pollForResult(requestId: requestId)
    }

    func transcribe(audioData: Data) async throws -> TranscriptionResult {
        flog("IPC transcribe: \(audioData.count) bytes")

        // Step 1: Submit audio, get request ID
        var request = URLRequest(url: IPCConfig.transcribeURL)
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let (data, _) = try await executeWithRetry(request: request, operation: "transcribe")

        let submitResponse: IPCSubmitResponse
        do {
            submitResponse = try JSONDecoder().decode(IPCSubmitResponse.self, from: data)
        } catch {
            flog("IPC submit decode failed: \(error.localizedDescription)")
            // This reaches the keyboard toolbar, so it has to be a sentence a user
            // can act on rather than the decoder's own words.
            throw IPCError.serverError("keyboard.error.badResponse".localized)
        }

        flog("IPC submitted, id=\(submitResponse.id.prefix(8))...")

        // Step 2: Poll for result
        return try await pollForResult(requestId: submitResponse.id)
    }

    /// Poll for transcription result with connection error tolerance
    /// Creates fresh URLSession for each poll to handle suspend/resume scenarios
    private func pollForResult(requestId: String) async throws -> TranscriptionResult {
        let deadline = Date().addingTimeInterval(IPCConfig.pollTimeout)
        var pollCount = 0
        var consecutiveErrors = 0
        var lastPollError = ""
        let maxConsecutiveErrors = 5 // Fail if 5 consecutive connection errors

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(IPCConfig.pollInterval * 1_000_000_000))
            pollCount += 1

            var pollRequest = URLRequest(url: IPCConfig.resultURL(for: requestId))
            pollRequest.timeoutInterval = 5

            // Create fresh session for each poll
            let session = createSession()
            defer { session.invalidateAndCancel() }

            do {
                let (data, _) = try await session.data(for: pollRequest)
                consecutiveErrors = 0 // Reset on success

                let result = try JSONDecoder().decode(IPCResultResponse.self, from: data)

                switch result.status {
                case "done":
                    let text = result.text ?? ""
                    let language = result.language ?? ""
                    flog("IPC got transcription after \(pollCount) polls: '\(text.prefix(50))'")
                    return TranscriptionResult(text: text, language: language)
                case "error":
                    let msg = result.error ?? "Unknown error"
                    flog("IPC transcription error: \(msg)")
                    throw IPCError.serverError(msg)
                case "processing":
                    continue
                default:
                    continue
                }
            } catch let error as IPCError {
                throw error
            } catch {
                consecutiveErrors += 1
                lastPollError = error.localizedDescription
                flog("IPC poll #\(pollCount) failed (\(consecutiveErrors) consecutive): \(lastPollError)")

                if consecutiveErrors >= maxConsecutiveErrors {
                    flog("IPC poll: too many consecutive errors, giving up")
                    throw IPCError.connectionFailed
                }
                continue
            }
        }

        flog("IPC poll timeout after \(pollCount) polls, last error: \(lastPollError)")
        throw IPCError.serverError("Timeout after \(pollCount) polls. Last: \(lastPollError)")
    }
}

enum IPCError: LocalizedError {
    case connectionFailed
    /// The app answered, but its audio engine would not start.
    case hostNotReady
    case serverError(String)

    /// Both reachable-but-useless and unreachable hosts are fixed the same way:
    /// open Corvin. The toolbar keys its wake button off this, never off the
    /// message text.
    var meansHostNeedsWaking: Bool {
        switch self {
        case .connectionFailed, .hostNotReady: return true
        case .serverError: return false
        }
    }

    /// Shown whenever the host app is not reachable. The keyboard extension cannot launch
    /// it (extensions have no UIApplication), so the user has to open it once — after that
    /// background mode is persisted and re-arms itself.
    static var hostAsleepMessage: String { "keyboard.error.hostAsleep".localized }

    /// Shown when the app is reachable but its microphone will not start.
    static var hostNotReadyMessage: String { "keyboard.error.hostNotReady".localized }

    /// One-line version for the toolbar, where the button carries the remedy and
    /// a sentence telling the user to open the app by hand would contradict it.
    var shortPrompt: String {
        switch self {
        case .connectionFailed: return "keyboard.error.hostAsleep.short".localized
        case .hostNotReady: return IPCError.hostNotReadyMessage
        case .serverError(let msg): return msg
        }
    }

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return IPCError.hostAsleepMessage
        case .hostNotReady: return IPCError.hostNotReadyMessage
        case .serverError(let msg): return msg
        }
    }
}
