import Foundation

/// Simple file logger for debugging on device when os_log is not accessible.
/// Writes to App Group shared container so both iOS app and keyboard extension can write to the same log.
class FileLogger {
    static let shared = FileLogger()

    private static let appGroup = "group.com.corvinvoice.app"
    private static let logFileName = "corvin.log"
    private static let maxLogSize = 100_000 // 100KB max, then truncate

    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.corvin.filelogger")
    private let source: String

    var logFilePath: String {
        return FileLogger.sharedLogPath()
    }

    private init() {
        // Determine source based on bundle ID
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if bundleId.contains("Keyboard") || bundleId.contains("keyboard") {
            source = "KBD"
        } else {
            #if os(macOS)
            source = "MAC"
            #else
            source = "APP"
            #endif
        }

        let path = FileLogger.sharedLogPath()

        // Create directory if needed
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[FileLogger] FAILED to create directory \(dir): \(error)")
        }

        // Truncate if too large (only APP does this to avoid race)
        if source != "KBD" {
            truncateIfNeeded(path: path)
        }

        // Create file if doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            let created = FileManager.default.createFile(atPath: path, contents: nil)
            if !created {
                NSLog("[FileLogger] FAILED to create log file at \(path)")
            }
        }

        fileHandle = FileHandle(forWritingAtPath: path)
        if fileHandle == nil {
            NSLog("[FileLogger] FAILED to open FileHandle for \(path)")
        }
        fileHandle?.seekToEndOfFile()

        NSLog("[FileLogger] initialized: path=\(path), handle=\(fileHandle != nil ? "OK" : "nil")")
        // Log startup
        log("=== \(source) started ===")
    }

    private static func sharedLogPath() -> String {
        #if os(macOS)
        // macOS: use Application Support (reliable in sandbox, no App Group needed)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("Corvin").appendingPathComponent(logFileName).path
        }
        #else
        // iOS: use App Group so both app and keyboard extension share the log
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return groupURL.appendingPathComponent(logFileName).path
        }
        #endif
        // Fallback to Documents
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(logFileName).path
    }

    private func truncateIfNeeded(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size > FileLogger.maxLogSize else { return }

        // Keep last 50KB
        if let data = FileManager.default.contents(atPath: path) {
            let keepBytes = 50_000
            let startIndex = max(0, data.count - keepBytes)
            let truncated = data.suffix(from: startIndex)

            // Find first newline to start from clean line
            if let newlineIndex = truncated.firstIndex(of: 0x0A) {
                let cleanData = truncated.suffix(from: truncated.index(after: newlineIndex))
                try? cleanData.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let entry = "[\(ts)] [\(source)] \(filename):\(line) \(message)\n"
        queue.async { [weak self] in
            guard let self = self, let data = entry.data(using: .utf8) else { return }

            // Try to write, reopen file handle if it fails (can happen after app suspend)
            do {
                try self.writeData(data)
            } catch {
                // File handle may be stale after suspend, reopen it
                self.reopenFileHandle()
                try? self.writeData(data)
            }
        }
    }

    private func writeData(_ data: Data) throws {
        guard let handle = fileHandle else {
            throw NSError(domain: "FileLogger", code: 1, userInfo: nil)
        }
        if #available(iOS 13.4, *) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    private func reopenFileHandle() {
        fileHandle?.closeFile()
        fileHandle = nil

        let path = FileLogger.sharedLogPath()

        // Create file if doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        fileHandle = FileHandle(forWritingAtPath: path)
    }

    func readAll() -> String {
        return (try? String(contentsOfFile: FileLogger.sharedLogPath(), encoding: .utf8)) ?? ""
    }

    /// Read last N lines efficiently without loading entire file
    func readTail(lines: Int = 50) -> String {
        let path = FileLogger.sharedLogPath()
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }

        // Read last 100KB max (should be plenty for 50-200 lines)
        let maxBytes: UInt64 = 100_000
        let fileSize = handle.seekToEndOfFile()

        let startPos = fileSize > maxBytes ? fileSize - maxBytes : 0
        handle.seek(toFileOffset: startPos)

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }

        let allLines = text.components(separatedBy: "\n")
        let tail = allLines.suffix(lines)
        return tail.joined(separator: "\n")
    }

    /// Clear log file
    func clear() {
        queue.async { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil

            let path = FileLogger.sharedLogPath()
            try? FileManager.default.removeItem(atPath: path)
            FileManager.default.createFile(atPath: path, contents: nil)

            self?.fileHandle = FileHandle(forWritingAtPath: path)
            self?.log("=== Log cleared ===")
        }
    }
}

func flog(_ message: String, file: String = #file, line: Int = #line) {
    FileLogger.shared.log(message, file: file, line: line)
}
