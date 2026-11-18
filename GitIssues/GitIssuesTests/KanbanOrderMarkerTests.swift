//
//  KanbanOrderMarkerTests.swift
//  GitIssuesTests
//
//  Issue #109: the order key is parsed once when an Issue is created (not per board render); the
//  parsing behaviour itself must be unchanged.
//

import XCTest
@testable import GitIssues

@MainActor
final class KanbanOrderMarkerTests: XCTestCase {
    func testParseFindsKey() {
        XCTAssertEqual(KanbanOrderMarker.parse(from: "Text\n\n<!-- gitissues:order=a0V -->"), "a0V")
        XCTAssertEqual(KanbanOrderMarker.parse(from: "<!--gitissues:order=Zz-->"), "Zz", "Whitespace inside the comment is optional")
    }

    func testParseReturnsNilWithoutMarker() {
        XCTAssertNil(KanbanOrderMarker.parse(from: nil))
        XCTAssertNil(KanbanOrderMarker.parse(from: ""))
        XCTAssertNil(KanbanOrderMarker.parse(from: "plain body mentioning gitissues"))
        XCTAssertNil(KanbanOrderMarker.parse(from: "<!-- some other comment -->"))
        XCTAssertNil(KanbanOrderMarker.parse(from: "gitissues:order=abc but not a comment"))
    }

    func testStripRemovesMarkerAndTrims() {
        XCTAssertEqual(KanbanOrderMarker.strip(from: "Hello\n\n<!-- gitissues:order=a1 -->"), "Hello")
        XCTAssertEqual(KanbanOrderMarker.strip(from: "  no marker  \n"), "no marker")
        XCTAssertEqual(KanbanOrderMarker.strip(from: nil), "")
    }

    func testInjectReplacesExistingMarkerAndRoundTrips() {
        let once = KanbanOrderMarker.inject("k1", into: "Body")
        XCTAssertEqual(KanbanOrderMarker.parse(from: once), "k1")
        let twice = KanbanOrderMarker.inject("k2", into: once)
        XCTAssertEqual(KanbanOrderMarker.parse(from: twice), "k2")
        XCTAssertEqual(KanbanOrderMarker.strip(from: twice), "Body")
        XCTAssertEqual(KanbanOrderMarker.inject("k", into: nil), "<!-- gitissues:order=k -->")
    }

    // MARK: - Issue.kanbanOrderKey

    func testIssueKeyIsDerivedFromBodyAtCreation() {
        let keyed = Fixture.issue(body: "Text\n<!-- gitissues:order=m5 -->")
        XCTAssertEqual(keyed.kanbanOrderKey, "m5")
        XCTAssertNil(Fixture.issue(body: "Text").kanbanOrderKey)
        XCTAssertNil(Fixture.issue(body: nil).kanbanOrderKey)
    }

    func testCodableRoundTripKeepsBodyAndKey() throws {
        let original = Fixture.issue(id: "X", body: "Hi\n<!-- gitissues:order=q9 -->", labels: ["bug"])
        let data = try JSONEncoder().encode(original)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["kanbanOrderKey"], "Derived from the body, so it is not encoded")

        let decoded = try JSONDecoder().decode(Issue.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kanbanOrderKey, "q9")
    }
}
