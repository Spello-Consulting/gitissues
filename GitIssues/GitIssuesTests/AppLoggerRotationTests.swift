//
//  AppLoggerRotationTests.swift
//  GitIssuesTests
//
//  Issue #122: configurable log file size and file count.
//

import XCTest
@testable import GitIssues

final class AppLoggerRotationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var logger: AppLogger!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppLoggerTests-\(UUID().uuidString)")
        suiteName = "AppLoggerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(LogLevel.debug.rawValue, forKey: AppLogger.logLevelKey)
        logger = AppLogger(directory: directory, defaults: defaults)
    }

    override func tearDown() {
        logger.flush()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func fileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func writeLines(_ count: Int) {
        // ~600 KB per line so a 1 MB limit is exceeded every couple of writes.
        let payload = String(repeating: "x", count: 600 * 1024)
        for _ in 0..<count { logger.info(payload) }
        logger.flush()
    }

    func testDefaults() {
        XCTAssertEqual(logger.maxFileSizeMB, 20)
        XCTAssertEqual(logger.maxFileCount, 10)
    }

    func testSettingsAreClampedToAllowedRange() {
        logger.maxFileSizeMB = 0
        logger.maxFileCount = 1000
        XCTAssertEqual(logger.maxFileSizeMB, AppLogger.maxFileSizeMBRange.lowerBound)
        XCTAssertEqual(logger.maxFileCount, AppLogger.maxFileCountRange.upperBound)

        logger.maxFileSizeMB = 9999
        logger.maxFileCount = -3
        XCTAssertEqual(logger.maxFileSizeMB, AppLogger.maxFileSizeMBRange.upperBound)
        XCTAssertEqual(logger.maxFileCount, AppLogger.maxFileCountRange.lowerBound)
    }

    func testRotatesAtConfiguredSizeAndKeepsConfiguredFileCount() {
        logger.maxFileSizeMB = 1
        logger.maxFileCount = 3
        writeLines(20)

        XCTAssertEqual(fileNames(), ["GitIssues-1.log", "GitIssues-2.log", "GitIssues.log"])
    }

    func testSingleFileLimitDiscardsInsteadOfArchiving() {
        logger.maxFileSizeMB = 1
        logger.maxFileCount = 1
        writeLines(10)

        XCTAssertEqual(fileNames(), ["GitIssues.log"])
    }

    func testLoweringFileCountTrimsSurplusArchives() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["GitIssues.log", "GitIssues-1.log", "GitIssues-2.log", "GitIssues-3.log", "GitIssues-4.log"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }

        logger.maxFileCount = 3
        logger.applyRetention()
        logger.flush()

        XCTAssertEqual(fileNames(), ["GitIssues-1.log", "GitIssues-2.log", "GitIssues.log"])
    }
}
