//
//  AppLogger.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import AppKit

/// Severity levels in descending order of seriousness. The raw value doubles as the
/// threshold ordering: a configured level logs every entry whose raw value is <= its own
/// (e.g. `.information` logs information, warnings and errors, but not debug).
nonisolated enum LogLevel: Int, CaseIterable, Identifiable {
    case error = 0
    case warning = 1
    case information = 2
    case debug = 3

    var id: Int { rawValue }

    /// User-facing name used in Settings.
    var displayName: String {
        switch self {
        case .error: return "Errors"
        case .warning: return "Warnings"
        case .information: return "Information"
        case .debug: return "Debug"
        }
    }

    /// Tag written into each log line.
    var tag: String {
        switch self {
        case .error: return "ERROR"
        case .warning: return "WARNING"
        case .information: return "INFO"
        case .debug: return "DEBUG"
        }
    }
}

/// Thread-safe file logger with size-based rotation.
///
/// Logs are written to the app's sandbox container at `Library/Logs` (resolved via
/// `FileManager`, i.e. `~/Library/Containers/<bundle-id>/Data/Library/Logs`). The active
/// file rotates when it reaches `maxFileSize`, retaining up to `maxFileCount` files total.
nonisolated final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    /// UserDefaults key for the persisted minimum severity. Shared with the Settings UI.
    static let logLevelKey = "logLevel"

    private let queue = DispatchQueue(label: "com.spelloconsulting.gitissues.logger", qos: .utility)
    private let fileManager = FileManager.default

    private let maxFileSize: UInt64 = 20 * 1024 * 1024 // 20 MB
    private let maxFileCount = 10                       // active + archives, 10 total
    private let baseName = "GitIssues"
    private let fileExtension = "log"

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private init() {}

    // MARK: - Configuration

    /// The minimum severity that will be written, persisted in UserDefaults. Defaults to `.information`.
    var currentLevel: LogLevel {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: Self.logLevelKey) != nil else { return .information }
            return LogLevel(rawValue: defaults.integer(forKey: Self.logLevelKey)) ?? .information
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.logLevelKey)
        }
    }

    // MARK: - Locations

    /// Directory containing the log files, creating it lazily on first write.
    var logDirectory: URL? {
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return library.appendingPathComponent("Logs", isDirectory: true)
    }

    private var activeLogFile: URL? {
        logDirectory?.appendingPathComponent("\(baseName).\(fileExtension)")
    }

    /// All current log files, sorted by name (active file first).
    func logFiles() -> [URL] {
        guard let directory = logDirectory else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix(baseName) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Public logging API

    func error(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.error, message, file: file, line: line)
    }

    func warning(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.warning, message, file: file, line: line)
    }

    func info(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.information, message, file: file, line: line)
    }

    func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.debug, message, file: file, line: line)
    }

    func log(_ level: LogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        guard level.rawValue <= currentLevel.rawValue else { return }

        let timestamp = dateFormatter.string(from: Date())
        let location = "\(file):\(line)"
        let entry = "[\(timestamp)] [\(level.tag)] \(message) (\(location))\n"

        queue.async { [weak self] in
            self?.write(entry)
        }
    }

    // MARK: - Management

    /// Opens the log directory in Finder, selecting the log files if present.
    func revealInFinder() {
        guard let directory = logDirectory else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = logFiles()
        if files.isEmpty {
            NSWorkspace.shared.open(directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    /// Deletes all log files.
    func deleteAllLogs() {
        queue.async { [weak self] in
            guard let self, let directory = self.logDirectory else { return }
            let contents = (try? self.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in contents where file.pathExtension == self.fileExtension && file.lastPathComponent.hasPrefix(self.baseName) {
                try? self.fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - File writing (serial queue only)

    private func write(_ text: String) {
        guard let directory = logDirectory, let file = activeLogFile else { return }
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            rotateIfNeeded(activeFile: file)

            guard let data = text.data(using: .utf8) else { return }
            if fileManager.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(data)
            } else {
                try data.write(to: file, options: .atomic)
            }
        } catch {
            // The logger itself failing should never crash the app; fall back to stderr.
            print("AppLogger write failed: \(error)")
        }
    }

    /// Rotates the active file when it reaches the size limit, shifting archives down and
    /// dropping the oldest so that no more than `maxFileCount` files are retained.
    private func rotateIfNeeded(activeFile: URL) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: activeFile.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size >= maxFileSize,
              let directory = logDirectory else {
            return
        }

        let archiveCount = maxFileCount - 1 // archives: GitIssues-1.log ... GitIssues-<archiveCount>.log

        // Drop the oldest archive, if it exists.
        let oldest = directory.appendingPathComponent("\(baseName)-\(archiveCount).\(fileExtension)")
        try? fileManager.removeItem(at: oldest)

        // Shift remaining archives down: -<n> becomes -<n+1>.
        var index = archiveCount - 1
        while index >= 1 {
            let from = directory.appendingPathComponent("\(baseName)-\(index).\(fileExtension)")
            let to = directory.appendingPathComponent("\(baseName)-\(index + 1).\(fileExtension)")
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: from, to: to)
            }
            index -= 1
        }

        // The active file becomes the newest archive.
        let firstArchive = directory.appendingPathComponent("\(baseName)-1.\(fileExtension)")
        try? fileManager.moveItem(at: activeFile, to: firstArchive)
    }
}
