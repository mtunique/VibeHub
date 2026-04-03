import Foundation
import os.log

actor RemoteLog {
    static let shared = RemoteLog()

    enum Level: String {
        case debug
        case info
        case warn
        case error
    }

    private let logger = Logger(subsystem: "com.vibehub", category: "Remote")
    private var fileHandle: FileHandle?
    private var logFileURL: URL?

    private init() {
        // Lazy-open on first log call. (Actor init is nonisolated in Swift 6.)
    }

    /// Ensure the log file exists and return its path.
    func ensureLogFile() -> String? {
        if fileHandle == nil {
            openFileIfPossible()
        }
        return logFileURL?.path
    }

    func log(_ level: Level, _ message: String, hostId: String? = nil) {
        let prefix = hostId.map { "[\($0)] " } ?? ""
        let line = "\(isoNow()) [\(level.rawValue.uppercased())] \(prefix)\(message)\n"

        switch level {
        case .debug:
            logger.debug("\(prefix, privacy: .public)\(message, privacy: .public)")
        case .info:
            logger.info("\(prefix, privacy: .public)\(message, privacy: .public)")
        case .warn:
            logger.warning("\(prefix, privacy: .public)\(message, privacy: .public)")
        case .error:
            logger.error("\(prefix, privacy: .public)\(message, privacy: .public)")
        }

        if fileHandle == nil { openFileIfPossible() }
        if let data = line.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }

    private func openFileIfPossible() {
        let fm = FileManager.default

        // Prefer ~/Library/Logs (classic macOS location), but fall back to Application Support
        // (works even in more restricted environments).
        var candidates: [URL] = []

        candidates.append(
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Logs")
                .appendingPathComponent("VibeHub")
        )

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("VibeHub").appendingPathComponent("Logs"))
        }

        candidates.append(fm.temporaryDirectory.appendingPathComponent("VibeHub").appendingPathComponent("Logs"))

        for dir in candidates {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("remote.log")
                if !fm.fileExists(atPath: file.path) {
                    fm.createFile(atPath: file.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                fileHandle = handle
                logFileURL = file
                logger.info("Remote log file: \(file.path, privacy: .public)")
                return
            } catch {
                continue
            }
        }

        // If all candidates fail, fall back to OSLog only.
        fileHandle = nil
        logFileURL = nil
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
