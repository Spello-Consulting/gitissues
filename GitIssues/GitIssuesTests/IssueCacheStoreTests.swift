//
//  IssueCacheStoreTests.swift
//  GitIssuesTests
//
//  Issue #109: the on-disk issue cache.
//

import XCTest
@testable import GitIssues

@MainActor
final class IssueCacheStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var store: IssueCacheStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("IssueCacheStoreTests-\(UUID().uuidString)")
        fileURL = directory.appendingPathComponent("IssueCache").appendingPathComponent("issues.json")
        store = IssueCacheStore(fileURL: fileURL)
    }

    override func tearDown() async throws {
        await store.waitForPendingWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(
        issues: [Issue] = [Fixture.issue(id: "A")],
        schemaVersion: Int = IssueCacheStore.schemaVersion,
        login: String = "me"
    ) -> CachedIssueSnapshot {
        CachedIssueSnapshot(
            schemaVersion: schemaVersion,
            userLogin: login,
            savedAt: t0,
            lastFullSyncAt: t0.addingTimeInterval(-60),
            lastSyncAt: t0.addingTimeInterval(-30),
            allowReadOnly: true,
            issues: issues
        )
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    func testMissingFileLoadsNil() async {
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    func testRoundTripPreservesIssuesAndSyncState() async throws {
        let issues = [
            Fixture.issue(id: "A", title: "First", body: "Hi\n<!-- gitissues:order=m5 -->", state: .open, labels: ["bug", "kanban-Review"]),
            Fixture.issue(id: "B", title: "Second", state: .closed, updatedAt: t0)
        ]
        store.save(snapshot(issues: issues), generation: store.generation)
        await store.waitForPendingWrites()

        let result = await store.load()
        let loaded = try XCTUnwrap(result)

        XCTAssertEqual(loaded.issues, issues)
        XCTAssertEqual(loaded.issues.first?.kanbanOrderKey, "m5")
        XCTAssertEqual(loaded.userLogin, "me")
        XCTAssertEqual(loaded.lastFullSyncAt, t0.addingTimeInterval(-60))
        XCTAssertEqual(loaded.lastSyncAt, t0.addingTimeInterval(-30))
        XCTAssertTrue(loaded.allowReadOnly)
    }

    func testLaterSaveWinsWhenSavesAreQueued() async throws {
        store.save(snapshot(issues: [Fixture.issue(id: "old")]), generation: store.generation)
        store.save(snapshot(issues: [Fixture.issue(id: "new")]), generation: store.generation)

        let result = await store.load()
        let loaded = try XCTUnwrap(result)
        XCTAssertEqual(loaded.issues.map(\.id), ["new"])
    }

    func testOtherSchemaVersionIsDiscardedAndFileRemoved() async {
        store.save(snapshot(schemaVersion: IssueCacheStore.schemaVersion + 1), generation: store.generation)
        await store.waitForPendingWrites()
        XCTAssertTrue(fileExists)

        let loaded = await store.load()
        await store.waitForPendingWrites()

        XCTAssertNil(loaded)
        XCTAssertFalse(fileExists)
    }

    func testCorruptFileIsDiscardedAndFileRemoved() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)

        let loaded = await store.load()
        await store.waitForPendingWrites()

        XCTAssertNil(loaded)
        XCTAssertFalse(fileExists)
    }

    func testClearRemovesFile() async {
        store.save(snapshot(), generation: store.generation)
        await store.waitForPendingWrites()
        XCTAssertTrue(fileExists)

        store.clear()
        await store.waitForPendingWrites()

        XCTAssertFalse(fileExists)
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    func testSaveFromBeforeClearCannotResurrectTheCache() async {
        // A debounced save that fires after sign-out must not bring the old account's issues back.
        let staleGeneration = store.generation
        store.clear()

        store.save(snapshot(), generation: staleGeneration)
        await store.waitForPendingWrites()

        XCTAssertFalse(fileExists)
        XCTAssertEqual(store.generation, staleGeneration + 1)
    }

    func testSaveAfterClearWithCurrentGenerationWorks() async throws {
        store.clear()
        store.save(snapshot(login: "next"), generation: store.generation)

        let result = await store.load()
        let loaded = try XCTUnwrap(result)
        XCTAssertEqual(loaded.userLogin, "next")
    }
}
