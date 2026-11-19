//
//  GraphQLNotFoundTests.swift
//  GitIssuesTests
//
//  Issue #109 follow-up: an issue deleted on github.com must be reported as "not found" (so the
//  app can drop it from the list) rather than as a decoding failure.
//

import XCTest
@testable import GitIssues

@MainActor
final class GraphQLNotFoundTests: XCTestCase {
    private func decode(_ json: String) throws -> GraphQLResponse<IssueDetailResponse> {
        try JSONDecoder().decode(GraphQLResponse<IssueDetailResponse>.self, from: Data(json.utf8))
    }

    func testDeletedIssueResponseDecodesAndIsMarkedNotFound() throws {
        let response = try decode("""
        {"data":{"repository":{"issue":null}},
         "errors":[{"type":"NOT_FOUND","path":["repository","issue"],
                    "message":"Could not resolve to an Issue with the number of 113."}]}
        """)

        XCTAssertNil(response.data?.repository?.issue)
        XCTAssertEqual(response.errors?.count, 1)
        XCTAssertTrue(response.errors?.first?.isNotFound == true)
    }

    func testMissingRepositoryResponseDecodes() throws {
        let response = try decode("""
        {"data":{"repository":null},
         "errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository."}]}
        """)

        XCTAssertNil(response.data?.repository)
        XCTAssertTrue(response.errors?.first?.isNotFound == true)
    }

    func testOtherErrorTypesAreNotNotFound() throws {
        let response = try decode("""
        {"data":{"repository":null},
         "errors":[{"type":"FORBIDDEN","message":"Resource not accessible."},
                   {"message":"An error without a type"}]}
        """)

        XCTAssertEqual(response.errors?.map(\.isNotFound), [false, false])
    }

    func testNotFoundHasFriendlyDescription() {
        XCTAssertEqual(GraphQLError.notFound.localizedDescription, "This item no longer exists on GitHub.")
    }
}
