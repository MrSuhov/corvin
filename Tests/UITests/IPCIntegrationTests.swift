import XCTest

/// Integration test for IPC transcription flow.
/// Tests the full IPC flow without requiring keyboard UI:
/// 1. Launch Corvin app to start IPC server
/// 2. Enable test mode with mock audio
/// 3. Call /start-recording
/// 4. Call /stop-recording
/// 5. Poll /result and verify transcription
final class IPCIntegrationTests: XCTestCase {

    var app: XCUIApplication!
    let baseURL = "http://127.0.0.1:12345"

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Launch Corvin app to start IPC server
        app = XCUIApplication(bundleIdentifier: "com.corvinvoice.ios")
        app.launch()

        // Wait for IPC server to start
        sleep(3)

        // Verify server is running
        let pingOk = ping()
        XCTAssertTrue(pingOk, "IPC server should be running")
    }

    override func tearDownWithError() throws {
        // Disable test mode
        disableTestMode()

        // Print logs for debugging
        printAppLogs()
    }

    // MARK: - Tests

    func testIPCTranscriptionFlow() throws {
        // 1. Enable test mode with Russian audio
        let testModeEnabled = enableTestMode(audio: "rus")
        XCTAssertTrue(testModeEnabled, "Test mode should be enabled")

        // 2. Start recording
        let startResult = startRecording()
        XCTAssertNotNil(startResult, "Start recording should return a response")
        XCTAssertEqual(startResult?["status"] as? String, "recording", "Status should be 'recording'")

        let recordingId = startResult?["id"] as? String
        XCTAssertNotNil(recordingId, "Should have recording ID")

        // 3. Wait a bit (simulating recording time)
        sleep(1)

        // 4. Stop recording and get transcription ID
        let stopResult = stopRecording()
        XCTAssertNotNil(stopResult, "Stop recording should return a response")

        let transcriptionId = stopResult?["id"] as? String
        XCTAssertNotNil(transcriptionId, "Should have transcription ID")
        XCTAssertEqual(transcriptionId, recordingId, "Transcription ID should match recording ID")

        // 5. Poll for result
        let result = pollForResult(id: transcriptionId!, timeout: 60)
        XCTAssertNotNil(result, "Should get transcription result")
        XCTAssertEqual(result?["status"] as? String, "done", "Status should be 'done'")

        let text = result?["text"] as? String
        XCTAssertNotNil(text, "Should have transcription text")
        XCTAssertFalse(text!.isEmpty, "Transcription text should not be empty")

        print("Transcription result: '\(text!)'")
    }

    func testIPCDirectTranscribe() throws {
        // Test the direct /transcribe endpoint with audio data

        // 1. Enable test mode to get test audio
        let testModeEnabled = enableTestMode(audio: "eng")
        XCTAssertTrue(testModeEnabled, "Test mode should be enabled")

        // 2. Load test audio data
        guard let audioData = loadTestAudio(name: "eng_test") else {
            XCTFail("Could not load test audio")
            return
        }

        // 3. Submit for transcription
        let submitResult = submitTranscription(audioData: audioData)
        XCTAssertNotNil(submitResult, "Submit should return a response")

        let transcriptionId = submitResult?["id"] as? String
        XCTAssertNotNil(transcriptionId, "Should have transcription ID")

        // 4. Poll for result
        let result = pollForResult(id: transcriptionId!, timeout: 60)
        XCTAssertNotNil(result, "Should get transcription result")
        XCTAssertEqual(result?["status"] as? String, "done", "Status should be 'done'")

        let text = result?["text"] as? String
        XCTAssertNotNil(text, "Should have transcription text")
        print("Transcription result: '\(text!)'")
    }

    // MARK: - HTTP Helpers

    private func ping() -> Bool {
        let url = URL(string: "\(baseURL)/ping")!
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                success = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return success
    }

    private func enableTestMode(audio: String) -> Bool {
        let url = URL(string: "\(baseURL)/test-mode?audio=\(audio)")!
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let testMode = json["testMode"] as? String,
               testMode == "on" {
                success = true
                print("Test mode enabled: \(json)")
            } else if let data = data, let str = String(data: data, encoding: .utf8) {
                print("Test mode response: \(str)")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return success
    }

    private func disableTestMode() {
        let url = URL(string: "\(baseURL)/test-mode?audio=off")!
        let semaphore = DispatchSemaphore(value: 0)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
    }

    private func startRecording() -> [String: Any]? {
        let url = URL(string: "\(baseURL)/start-recording")!
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json
                print("Start recording response: \(json)")
            } else if let error = error {
                print("Start recording error: \(error)")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    private func stopRecording() -> [String: Any]? {
        let url = URL(string: "\(baseURL)/stop-recording")!
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json
                print("Stop recording response: \(json)")
            } else if let error = error {
                print("Stop recording error: \(error)")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    private func submitTranscription(audioData: Data) -> [String: Any]? {
        let url = URL(string: "\(baseURL)/transcribe")!
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json
                print("Submit transcription response: \(json)")
            } else if let error = error {
                print("Submit transcription error: \(error)")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    private func pollForResult(id: String, timeout: TimeInterval) -> [String: Any]? {
        let url = URL(string: "\(baseURL)/result?id=\(id)")!
        let deadline = Date().addingTimeInterval(timeout)
        var pollCount = 0

        while Date() < deadline {
            pollCount += 1
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String: Any]?
            var shouldContinue = false

            URLSession.shared.dataTask(with: url) { data, response, error in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let status = json["status"] as? String ?? ""
                    if status == "processing" {
                        shouldContinue = true
                    } else {
                        result = json
                    }
                }
                semaphore.signal()
            }.resume()

            _ = semaphore.wait(timeout: .now() + 5)

            if let result = result {
                print("Poll #\(pollCount) got result: \(result)")
                return result
            }

            if shouldContinue {
                print("Poll #\(pollCount) - still processing...")
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            // Error or not found
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("Poll timeout after \(pollCount) attempts")
        return nil
    }

    private func loadTestAudio(name: String) -> Data? {
        // Try to load from the app bundle via IPC
        // For now, create minimal audio data for testing
        // In real scenario, the test audio files should be in the test bundle

        // Create a simple PCM audio buffer (1 second of silence at 16kHz)
        let sampleRate = 16000
        let duration = 1.0
        let sampleCount = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: sampleCount)

        // Add a simple tone to make it non-silent
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let frequency = 440.0 // A4 note
            samples[i] = Int16(sin(2.0 * Double.pi * frequency * t) * 1000)
        }

        return samples.withUnsafeBytes { Data($0) }
    }

    private func printAppLogs() {
        let url = URL(string: "\(baseURL)/log")!
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let logs = String(data: data, encoding: .utf8) {
                print("=== APP LOGS ===")
                print(logs)
                print("================")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
    }
}
