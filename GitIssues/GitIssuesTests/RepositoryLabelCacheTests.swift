//
//  RepositoryLabelCacheTests.swift
//  GitIssuesTests
//
//  Issue #109: the per-repository label cache that removes the label-listing round trip from
//  every Kanban move.
//

import XCTest
@testable import GitIssues

@MainActor
final class RepositoryLabelCacheTests: XCTestCase {
    func testEmptyCacheMissesAndIsNotPopulated() {
        let cache = RepositoryLabelCache()
        XCTAssertFalse(cache.isPopulated(repositoryID: "R1"))
        XCTAssertNil(cache.label(named: "bug", repositoryID: "R1"))
    }

    func testStoreThenLookupIsCaseInsensitive() {
        var cache = RepositoryLabelCache()
        cache.store([Fixture.label("Kanban-Review"), Fixture.label("bug")], repositoryID: "R1")

        XCTAssertTrue(cache.isPopulated(repositoryID: "R1"))
        XCTAssertEqual(cache.label(named: "kanban-review", repositoryID: "R1")?.id, "l-Kanban-Review")
        XCTAssertEqual(cache.label(named: "BUG", repositoryID: "R1")?.id, "l-bug")
        XCTAssertNil(cache.label(named: "missing", repositoryID: "R1"))
    }

    func testPopulatedEmptyRepositoryIsDistinctFromUnknown() {
        var cache = RepositoryLabelCache()
        cache.store([], repositoryID: "R1")
        XCTAssertTrue(cache.isPopulated(repositoryID: "R1"), "A repo with no labels is still 'loaded'")
        XCTAssertFalse(cache.isPopulated(repositoryID: "R2"))
    }

    func testRepositoriesAreIsolated() {
        var cache = RepositoryLabelCache()
        cache.store([Fixture.label("bug")], repositoryID: "R1")
        XCTAssertNil(cache.label(named: "bug", repositoryID: "R2"))
    }

    func testInsertAddsToPopulatedRepoOnly() {
        var cache = RepositoryLabelCache()
        cache.insert(Fixture.label("early"), repositoryID: "R1")
        XCTAssertFalse(cache.isPopulated(repositoryID: "R1"), "Inserting must not fake a fully-loaded repo")

        cache.store([Fixture.label("bug")], repositoryID: "R1")
        cache.insert(Fixture.label("kanban-New"), repositoryID: "R1")
        XCTAssertNotNil(cache.label(named: "kanban-new", repositoryID: "R1"))
        XCTAssertNotNil(cache.label(named: "bug", repositoryID: "R1"))
    }

    func testStoreReplacesPreviousContents() {
        var cache = RepositoryLabelCache()
        cache.store([Fixture.label("old")], repositoryID: "R1")
        cache.store([Fixture.label("new")], repositoryID: "R1")
        XCTAssertNil(cache.label(named: "old", repositoryID: "R1"))
        XCTAssertNotNil(cache.label(named: "new", repositoryID: "R1"))
    }

    func testInvalidateReportsWhetherAnythingWasCached() {
        var cache = RepositoryLabelCache()
        XCTAssertFalse(cache.invalidate(repositoryID: "R1"), "Nothing cached → a retry would not help")

        cache.store([Fixture.label("bug")], repositoryID: "R1")
        XCTAssertTrue(cache.invalidate(repositoryID: "R1"))
        XCTAssertFalse(cache.isPopulated(repositoryID: "R1"))
        XCTAssertFalse(cache.invalidate(repositoryID: "R1"))
    }
}
