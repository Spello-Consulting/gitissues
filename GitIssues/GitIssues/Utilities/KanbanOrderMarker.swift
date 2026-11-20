//
//  KanbanOrderMarker.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

/// Reads and writes a hidden Kanban order key stored as an HTML comment in an issue body.
///
/// The marker (`<!-- gitissues:order=KEY -->`) is invisible in GitHub's rendered markdown,
/// so it lets us persist per-issue board ordering without a visible change to the issue.
enum KanbanOrderMarker {
    /// Matches `<!-- gitissues:order=KEY -->` (key is any run of non-whitespace).
    private static let pattern = #"<!--\s*gitissues:order=([^\s]+)\s*-->"#

    /// Compiled once. Compiling an `NSRegularExpression` is far costlier than running it, and the
    /// marker is parsed for every issue (and was previously re-parsed on every board render).
    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// Cheap literal that every marker contains; bodies without it skip the regex entirely.
    private static let literal = "gitissues:order="

    /// The order key stored in `body`, if present.
    static func parse(from body: String?) -> String? {
        guard let body, body.contains(literal), let regex else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges >= 2,
              let keyRange = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[keyRange])
    }

    /// `body` with any order marker (and surrounding whitespace) removed.
    static func strip(from body: String?) -> String {
        guard let body else { return "" }
        guard body.contains(literal), let regex else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(body.startIndex..., in: body)
        let stripped = regex.stringByReplacingMatches(in: body, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `body` with the order marker set to `key`, replacing any existing marker.
    static func inject(_ key: String, into body: String?) -> String {
        let base = strip(from: body)
        let marker = "<!-- gitissues:order=\(key) -->"
        return base.isEmpty ? marker : base + "\n\n" + marker
    }
}
