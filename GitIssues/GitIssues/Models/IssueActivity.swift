//
//  IssueActivity.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

/// One entry in an issue's GitHub activity log (a label was added, the issue was closed, ...).
struct IssueActivity: Identifiable, Equatable {
    struct Actor: Equatable {
        let login: String
        let avatarUrl: String?
    }

    enum Kind: Equatable {
        case labeled(Label)
        case unlabeled(Label)
        case closed(reason: String?)
        case reopened
        case assigned(login: String?)
        case unassigned(login: String?)
        case renamed(from: String, to: String)
        case milestoned(title: String)
        case demilestoned(title: String)
        case locked(reason: String?)
        case unlocked
        case crossReferenced(number: Int, title: String, repository: String?, isPullRequest: Bool)
        case transferred(from: String?)
    }

    let id: String
    let actor: Actor?
    let createdAt: Date
    let kind: Kind

    /// Kanban state labels are an implementation detail of the board and are hidden everywhere
    /// else in the app, so their add/remove events are left out of the log too.
    var isKanbanLabelEvent: Bool {
        switch kind {
        case .labeled(let label), .unlabeled(let label):
            return Kanban.isKanbanLabel(label.name)
        default:
            return false
        }
    }

    /// The sentence that follows the actor's name, e.g. "closed this as completed". Label events
    /// are rendered with a coloured chip by the view; their text is `added the <name> label`.
    var phrase: String {
        switch kind {
        case .labeled(let label):
            return "added the \(label.name) label"
        case .unlabeled(let label):
            return "removed the \(label.name) label"
        case .closed(let reason):
            switch reason {
            case "COMPLETED": return "closed this as completed"
            case "NOT_PLANNED": return "closed this as not planned"
            case "DUPLICATE": return "closed this as a duplicate"
            default: return "closed this"
            }
        case .reopened:
            return "reopened this"
        case .assigned(let login):
            return login.map { "assigned \($0)" } ?? "assigned someone"
        case .unassigned(let login):
            return login.map { "unassigned \($0)" } ?? "unassigned someone"
        case .renamed(let from, let to):
            return "changed the title from “\(from)” to “\(to)”"
        case .milestoned(let title):
            return "added this to the \(title) milestone"
        case .demilestoned(let title):
            return "removed this from the \(title) milestone"
        case .locked(let reason):
            let readable: String? = {
                switch reason {
                case "OFF_TOPIC": return "off-topic"
                case "TOO_HEATED": return "too heated"
                case "RESOLVED": return "resolved"
                case "SPAM": return "spam"
                default: return nil
                }
            }()
            return readable.map { "locked this conversation as \($0)" } ?? "locked this conversation"
        case .unlocked:
            return "unlocked this conversation"
        case .crossReferenced(let number, let title, let repository, let isPullRequest):
            let noun = isPullRequest ? "pull request" : "issue"
            let ref = repository.map { "\($0)#\(number)" } ?? "#\(number)"
            return "mentioned this in \(noun) \(ref) \(title)"
        case .transferred(let from):
            return from.map { "transferred this issue from \($0)" } ?? "transferred this issue"
        }
    }

    /// SF Symbol for the event.
    var systemImage: String {
        switch kind {
        case .labeled, .unlabeled: return "tag"
        case .closed: return "checkmark.circle"
        case .reopened: return "arrow.counterclockwise.circle"
        case .assigned, .unassigned: return "person.crop.circle"
        case .renamed: return "pencil"
        case .milestoned, .demilestoned: return "flag"
        case .locked, .unlocked: return "lock"
        case .crossReferenced: return "arrow.turn.up.right"
        case .transferred: return "arrow.right.square"
        }
    }
}

/// A comment or activity event, ordered together in the issue detail panel.
enum ConversationEntry: Identifiable {
    case comment(Comment)
    case activity(IssueActivity)

    var id: String {
        switch self {
        case .comment(let comment): return "comment-\(comment.id)"
        case .activity(let event): return "activity-\(event.id)"
        }
    }

    var date: Date {
        switch self {
        case .comment(let comment): return comment.createdAt
        case .activity(let event): return event.createdAt
        }
    }

    /// Comments and activity events interleaved oldest-first, like GitHub's own timeline. When
    /// two entries share a timestamp the comment comes first. Kanban label events are dropped.
    static func merge(comments: [Comment], activity: [IssueActivity]) -> [ConversationEntry] {
        let entries = comments.map(ConversationEntry.comment)
            + activity.filter { !$0.isKanbanLabelEvent }.map(ConversationEntry.activity)
        return entries.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date {
                return lhs.element.date < rhs.element.date
            }
            // Same instant: keep comments before events, otherwise the original order.
            switch (lhs.element, rhs.element) {
            case (.comment, .activity): return true
            case (.activity, .comment): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
