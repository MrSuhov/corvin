import Foundation
import Network
import UIKit
import os.log

private let logger = Logger(subsystem: "com.corvin.ipc", category: "server")

/// Async HTTP server for IPC with the keyboard extension.
/// POST /transcribe — accepts audio, returns request ID immediately.
/// GET /result?id=xxx — returns processing status or transcription result.
/// Each HTTP request is short-lived (<100ms), so connections never drop.
class IPCServer {
    private let transcriptionService: TranscriptionService
    private let audioCaptureService: AudioCaptureService
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.corvin.ipc.server", qos: .userInitiated)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var healthCheckTimer: DispatchSourceTimer?
    private var lastConnectionTime: Date?
    private var lastHealthCheckTime: Date?
    private var lastEnsureRunningTime: Date?

    // In-memory store for pending/completed transcriptions
    private var results: [String: IPCResultResponse] = [:]
    private let resultsLock = NSLock()

    // Active recording session
    private var activeRecordingId: String?

    init(transcriptionService: TranscriptionService, audioCaptureService: AudioCaptureService) {
        self.transcriptionService = transcriptionService
        self.audioCaptureService = audioCaptureService
    }

    func start() {
        startListener()
        startHealthCheck()
    }

    /// Periodic health check to detect and recover from listener issues
    private func startHealthCheck() {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        // More aggressive health check: 10 seconds instead of 30
        timer.schedule(deadline: .now() + 10, repeating: .seconds(10), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.performHealthCheck()
        }
        timer.resume()
        healthCheckTimer = timer
        flog("IPC health check timer started (10s interval)")
    }

    private func performHealthCheck() {
        // Skip if restart is already in progress
        if isRestarting {
            flog("Health check: restart in progress, skipping")
            return
        }

        let now = Date()
        defer { lastHealthCheckTime = now }

        // Detect suspension: health check runs every 10s, so gap > 20s means we were suspended
        // NWListener can show state=ready but be a zombie after iOS suspension
        if let lastTime = lastHealthCheckTime {
            let gap = now.timeIntervalSince(lastTime)
            if gap > 20 {
                flog("Health check: detected suspension gap \(String(format: "%.1f", gap))s, forcing restart")
                startListener()
                return
            }
        }

        let state = listener?.state
        let stateStr: String
        switch state {
        case .ready: stateStr = "ready"
        case .failed: stateStr = "failed"
        case .cancelled: stateStr = "cancelled"
        case .waiting: stateStr = "waiting"
        case .setup: stateStr = "setup"
        case .none: stateStr = "nil"
        @unknown default: stateStr = "unknown"
        }

        if state != .ready {
            flog("Health check: listener unhealthy (state=\(stateStr)), restarting...")
            startListener()
        } else {
            // Log health check periodically for debugging
            let lastConn = lastConnectionTime.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "never"
            flog("Health check: listener OK, lastConnection=\(lastConn)")
        }
    }

    // Restart state - all protected by queue serialization
    private var restartCount = 0
    private var isRestarting = false  // Global mutex - only ONE restart path active
    private var activeConnections: [NWConnection] = []

    private func startListener() {
        // MUTEX: Only one restart operation at a time
        if isRestarting {
            flog("startListener: restart already in progress, skipping")
            return
        }

        isRestarting = true

        // If listener exists, cancel it first
        if let existingListener = listener {
            flog("startListener: cancelling existing listener")
            listener = nil
            existingListener.cancel()
            // Cancel all active connections
            for conn in activeConnections {
                conn.cancel()
            }
            activeConnections.removeAll()
        }

        // Wait for port to be freed (TCP TIME_WAIT workaround)
        // iOS doesn't properly implement SO_REUSEADDR for NWListener
        let delay = restartCount == 0 ? 0.5 : min(Double(restartCount) * 2.0, 30.0)
        flog("startListener: will create listener in \(String(format: "%.1f", delay))s (attempt #\(restartCount))")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.createAndStartListener()
        }
    }

    private func createAndStartListener() {
        // Double-check we're still in restart mode
        guard isRestarting else {
            flog("createAndStartListener: not in restart mode, skipping")
            return
        }

        // If listener already exists (race condition), skip
        if listener != nil {
            flog("createAndStartListener: listener already exists, skipping")
            isRestarting = false
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: IPCConfig.port) else {
            flog("invalid port: \(IPCConfig.port)")
            isRestarting = false
            return
        }

        do {
            listener = try NWListener(using: params, on: port)
            flog("NWListener created on port \(IPCConfig.port)")
        } catch {
            flog("listener creation failed: \(error.localizedDescription)")
            listener = nil
            scheduleRetry()
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                flog("HTTP server listening on port \(IPCConfig.port)")
                self.restartCount = 0
                self.isRestarting = false  // Success - release mutex
            case .failed(let error):
                flog("listener FAILED: \(error.localizedDescription)")
                self.listener = nil
                self.scheduleRetry()
            case .cancelled:
                flog("listener cancelled")
                // Don't release mutex here - let scheduleRetry handle it
            case .waiting(let error):
                flog("listener waiting: \(error.localizedDescription)")
            case .setup:
                flog("listener setup...")
            @unknown default:
                flog("listener unknown state: \(state)")
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    private func scheduleRetry() {
        restartCount += 1
        // Exponential backoff: 2s, 4s, 6s... max 30s
        let delay = min(Double(restartCount) * 2.0, 30.0)
        flog("scheduleRetry: attempt #\(restartCount) in \(String(format: "%.1f", delay))s")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // Clear old listener reference if any
            self.listener = nil
            self.createAndStartListener()
        }
    }

    func stop() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
        listener?.cancel()
        listener = nil
    }

    /// Check if listener is healthy and restart if needed
    func ensureRunning() {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Skip if restart already in progress
            if self.isRestarting {
                flog("ensureRunning: restart in progress, skipping")
                return
            }

            let now = Date()
            defer { self.lastEnsureRunningTime = now }

            // Detect suspension: ensureRunning fires every 5s, so gap > 10s means we were suspended
            // NWListener can show state=ready but be a zombie after iOS suspension
            if let lastTime = self.lastEnsureRunningTime {
                let gap = now.timeIntervalSince(lastTime)
                if gap > 10 {
                    flog("ensureRunning: detected suspension gap \(String(format: "%.1f", gap))s, forcing restart")
                    self.startListener()
                    return
                }
            }

            let state = self.listener?.state

            if state == .ready {
                flog("ensureRunning: listener healthy")
            } else {
                flog("ensureRunning: listener unhealthy, restarting...")
                self.startListener()
            }
        }
    }

    /// Force restart listener - use after app returns from background
    /// NWListener can show state=ready but be in "zombie" state not accepting connections
    func forceRestart() {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Skip if restart already in progress
            if self.isRestarting {
                flog("forceRestart: restart in progress, skipping")
                return
            }

            flog("forceRestart: restarting listener")
            self.startListener()
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        lastConnectionTime = Date()

        // Track connection for cleanup on listener cancel
        activeConnections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.queue.async {
                    self?.activeConnections.removeAll { $0 === connection }
                }
            }
        }

        connection.start(queue: queue)

        // Read HTTP request — short requests only, 1MB max
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self = self, let data = data else {
                connection.cancel()
                return
            }
            self.handleHTTPData(data: data, connection: connection)
        }
    }

    private func handleHTTPData(data: Data, connection: NWConnection) {
        // Find \r\n\r\n separator
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let sepRange = data.firstRange(of: Data(separator)) else {
            // Headers incomplete — read more
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] more, _, _, _ in
                guard let self = self else { connection.cancel(); return }
                var combined = data
                if let more = more { combined.append(more) }
                self.handleHTTPData(data: combined, connection: connection)
            }
            return
        }

        let headerEndIndex = sepRange.upperBound
        let headerData = data[data.startIndex..<sepRange.lowerBound]
        let headers = String(data: headerData, encoding: .utf8) ?? ""
        let requestLine = headers.components(separatedBy: "\r\n").first ?? ""

        // Extract Content-Length
        var contentLength = 0
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyData = data[headerEndIndex...]

        if bodyData.count < contentLength {
            let remaining = contentLength - bodyData.count
            connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] more, _, _, _ in
                guard let self = self else { connection.cancel(); return }
                var fullBody = Data(bodyData)
                if let more = more { fullBody.append(more) }
                self.routeRequest(requestLine: requestLine, body: fullBody, connection: connection)
            }
        } else {
            routeRequest(requestLine: requestLine, body: Data(bodyData.prefix(contentLength)), connection: connection)
        }
    }

    // MARK: - Routing

    private func routeRequest(requestLine: String, body: Data, connection: NWConnection) {
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.first ?? ""
        let path = parts.count > 1 ? parts[1] : ""

        flog("request: \(method) \(path)")

        if method == "POST" && path == "/start-recording" {
            handleStartRecording(connection: connection)
        } else if method == "POST" && path == "/stop-recording" {
            handleStopRecording(connection: connection)
        } else if method == "POST" && path == "/transcribe" {
            handleTranscribe(body: body, connection: connection)
        } else if method == "GET" && path.hasPrefix("/result") {
            handleResult(path: path, connection: connection)
        } else if method == "GET" && path == "/ping" {
            sendJSON(statusCode: 200, json: ["status": "ok"], connection: connection)
        } else if method == "POST" && path.hasPrefix("/test-mode") {
            handleTestMode(path: path, connection: connection)
        } else if method == "GET" && path == "/log" {
            let logText = FileLogger.shared.readTail(lines: 100)
            let body = logText.data(using: .utf8) ?? Data()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var responseData = header.data(using: .utf8) ?? Data()
            responseData.append(body)
            connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        } else {
            sendJSON(statusCode: 404, json: ["error": "not found"], connection: connection)
        }
    }

    // MARK: - POST /start-recording

    private func handleStartRecording(connection: NWConnection) {
        let requestId = UUID().uuidString
        flog("start-recording request \(requestId)")

        activeRecordingId = requestId

        resultsLock.lock()
        results[requestId] = IPCResultResponse(status: "processing", text: nil, language: nil, error: nil)
        resultsLock.unlock()

        beginBackground(name: "Recording")

        if let error = audioCaptureService.startCapture() {
            flog("audio engine failed to start: \(error.localizedDescription)")
            activeRecordingId = nil
            endBackground()

            // Store error result so polling will find it
            resultsLock.lock()
            results[requestId] = IPCResultResponse(status: "error", text: nil, language: nil, error: error.localizedDescription)
            resultsLock.unlock()

            sendJSON(statusCode: 500, json: ["id": requestId, "error": error.localizedDescription], connection: connection)
            return
        }

        flog("audio engine started from IPC")

        // Update PiP indicator
        Task { @MainActor in
            PiPService.shared.setRecording(true)
        }

        sendJSON(statusCode: 200, json: ["id": requestId, "status": "recording"], connection: connection)
    }

    // MARK: - POST /stop-recording

    private func handleStopRecording(connection: NWConnection) {
        // Update PiP indicator
        Task { @MainActor in
            PiPService.shared.setRecording(false)
        }

        guard let requestId = activeRecordingId else {
            sendJSON(statusCode: 400, json: ["error": "no active recording"], connection: connection)
            return
        }

        activeRecordingId = nil
        flog("stop-recording request \(requestId)")

        // Return ID immediately so keyboard can start polling
        sendJSON(statusCode: 200, json: ["id": requestId, "status": "transcribing"], connection: connection)

        // Stop recording and transcribe
        beginBackground(name: "StopAndTranscribe")

        let audioData = audioCaptureService.stopCapture()
        flog("captured \(audioData.count) bytes of audio")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            defer { self.endBackground() }

            guard audioData.count >= 16000 else {
                let dur = String(format: "%.2f", Double(audioData.count) / 32000.0)
                flog("audio too short: \(audioData.count) bytes (\(dur)s)")
                self.setResult(id: requestId, response: IPCResultResponse(
                    status: "error", text: nil, language: nil, error: "Аудио слишком короткое (\(dur)с)"
                ))
                return
            }

            do {
                flog("starting transcription for \(requestId)")
                let result = try await self.transcriptionService.transcribe(audioData: audioData)
                flog("transcription done for \(requestId): '\(result.text.prefix(50))'")
                self.setResult(id: requestId, response: IPCResultResponse(
                    status: "done", text: result.text, language: result.language, error: nil
                ))
            } catch {
                flog("transcription error for \(requestId): \(error.localizedDescription)")
                self.setResult(id: requestId, response: IPCResultResponse(
                    status: "error", text: nil, language: nil, error: error.localizedDescription
                ))
            }
        }
    }

    // MARK: - POST /transcribe

    private func handleTranscribe(body: Data, connection: NWConnection) {
        let requestId = UUID().uuidString
        flog("transcribe request \(requestId), audio: \(body.count) bytes")

        // Store "processing" status
        resultsLock.lock()
        results[requestId] = IPCResultResponse(status: "processing", text: nil, language: nil, error: nil)
        resultsLock.unlock()

        // Return ID immediately
        let response = IPCSubmitResponse(id: requestId)
        let jsonData = (try? JSONEncoder().encode(response)) ?? Data()
        sendHTTPResponse(statusCode: 200, body: jsonData, connection: connection)

        // Start transcription in background
        beginBackground(name: "Transcription")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            defer { self.endBackground() }

            do {
                flog("starting transcription for \(requestId)")
                let result = try await self.transcriptionService.transcribe(audioData: body)
                flog("transcription done for \(requestId): '\(result.text.prefix(50))'")
                self.setResult(id: requestId, response: IPCResultResponse(
                    status: "done", text: result.text, language: result.language, error: nil
                ))
            } catch {
                flog("transcription error for \(requestId): \(error.localizedDescription)")
                self.setResult(id: requestId, response: IPCResultResponse(
                    status: "error", text: nil, language: nil, error: error.localizedDescription
                ))
            }
        }
    }

    // MARK: - POST /test-mode?audio=rus|eng|off

    private func handleTestMode(path: String, connection: NWConnection) {
        // Parse audio parameter: /test-mode?audio=rus or /test-mode?audio=off
        let audioParam = path.components(separatedBy: "audio=").last?.components(separatedBy: "&").first ?? ""

        if audioParam == "off" || audioParam.isEmpty {
            audioCaptureService.testAudioURL = nil
            flog("test-mode: OFF")
            sendJSON(statusCode: 200, json: ["status": "ok", "testMode": "off"], connection: connection)
            return
        }

        // Look for test audio in bundle
        let filename = "\(audioParam)_test"
        if let url = Bundle.main.url(forResource: filename, withExtension: "pcm") {
            audioCaptureService.testAudioURL = url
            flog("test-mode: ON, audio=\(filename).pcm")
            sendJSON(statusCode: 200, json: ["status": "ok", "testMode": "on", "audio": filename], connection: connection)
        } else {
            flog("test-mode: audio file not found: \(filename).pcm")
            sendJSON(statusCode: 404, json: ["error": "audio file not found: \(filename).pcm"], connection: connection)
        }
    }

    // MARK: - GET /result?id=xxx

    private func handleResult(path: String, connection: NWConnection) {
        guard let idParam = path.components(separatedBy: "id=").last, !idParam.isEmpty else {
            sendJSON(statusCode: 400, json: ["error": "missing id"], connection: connection)
            return
        }

        resultsLock.lock()
        let result = results[idParam]
        if let r = result, r.status != "processing" {
            results.removeValue(forKey: idParam)
        }
        resultsLock.unlock()

        flog("GET /result id=\(idParam.prefix(8))... status=\(result?.status ?? "nil")")

        guard let result = result else {
            sendJSON(statusCode: 404, json: ["error": "not found"], connection: connection)
            return
        }

        let jsonData = (try? JSONEncoder().encode(result)) ?? Data()
        sendHTTPResponse(statusCode: 200, body: jsonData, connection: connection)
    }

    // MARK: - Helpers

    private func setResult(id: String, response: IPCResultResponse) {
        resultsLock.lock()
        results[id] = response
        resultsLock.unlock()
    }

    private func sendJSON(statusCode: Int, json: [String: String], connection: NWConnection) {
        let jsonData = (try? JSONEncoder().encode(json)) ?? Data()
        sendHTTPResponse(statusCode: statusCode, body: jsonData, connection: connection)
    }

    private func sendHTTPResponse(statusCode: Int, body: Data, connection: NWConnection) {
        let statusText = statusCode == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = header.data(using: .utf8) ?? Data()
        responseData.append(body)

        connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func beginBackground(name: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.backgroundTask == .invalid else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.endBackground()
            }
            logger.info("background task started: \(name)")
        }
    }

    private func endBackground() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
}
