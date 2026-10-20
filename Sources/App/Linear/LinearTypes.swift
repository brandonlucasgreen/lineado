import Foundation

// MARK: - Wire types

/// One issue as Linear sends it.
///
/// **Every field is Optional, and that is the whole point.** Swift's synthesised
/// `Decodable` does *not* fall back to a property's default value when a key is
/// missing — it throws `keyNotFound`, and one missing key fails the entire
/// decode, which here means the entire poll and so the entire list. Optional
/// properties are the one shape the synthesised initialiser treats as "absent is
/// fine" (it uses `decodeIfPresent` for them automatically).
///
/// So absence is modelled here and defaults are supplied in `LinearMapper`,
/// which is where domain decisions belong anyway. A *type mismatch* still
/// throws, deliberately: a string where an Int belongs means the schema moved
/// and should be loud.
struct IssueNode: Decodable, Sendable {
    struct StateNode: Decodable, Sendable {
        var id: String?
        var name: String?
        var type: String?
        var color: String?
        var position: Double?
        var team: TeamNode?
    }
    struct TeamNode: Decodable, Sendable {
        var id: String?
        var key: String?
        var name: String?
    }
    struct ProjectNode: Decodable, Sendable {
        var id: String?
        var name: String?
    }
    struct MilestoneNode: Decodable, Sendable {
        var id: String?
        var name: String?
        var targetDate: String?
    }
    struct LabelNode: Decodable, Sendable {
        var id: String?
        var name: String?
        var color: String?
    }
    struct LabelConnection: Decodable, Sendable {
        var nodes: [LabelNode]?
    }
    struct ParentNode: Decodable, Sendable {
        var id: String?
        var identifier: String?
        var title: String?
    }

    var id: String?
    var identifier: String?
    var title: String?
    var url: String?
    var branchName: String?
    /// 0–4. Linear's own scale; see `Priority`.
    var priority: Int?
    var priorityLabel: String?
    /// A bare `yyyy-MM-dd`, Linear's `TimelessDate`.
    var dueDate: String?
    var createdAt: Date?
    var updatedAt: Date?
    var state: StateNode?
    var team: TeamNode?
    var project: ProjectNode?
    var projectMilestone: MilestoneNode?
    var labels: LabelConnection?
    var parent: ParentNode?
}

struct PageInfo: Decodable, Sendable {
    var hasNextPage: Bool?
    var endCursor: String?
}

// MARK: - Query payloads

struct AssignedIssuesPayload: Decodable, Sendable {
    struct Viewer: Decodable, Sendable {
        struct Connection: Decodable, Sendable {
            var pageInfo: PageInfo?
            var nodes: [IssueNode]?
        }
        struct Organization: Decodable, Sendable {
            var id: String?
            var name: String?
            var urlKey: String?
        }
        var id: String?
        var name: String?
        var organization: Organization?
        var assignedIssues: Connection?
    }
    var viewer: Viewer
}

struct WorkflowStatesPayload: Decodable, Sendable {
    struct Connection: Decodable, Sendable {
        var pageInfo: PageInfo?
        var nodes: [IssueNode.StateNode]?
    }
    var workflowStates: Connection
}

struct IssueDetailPayload: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        var id: String?
        var description: String?
        var comments: CommentConnection?
    }
    struct CommentConnection: Decodable, Sendable {
        var nodes: [CommentNode]?
    }
    var issue: Detail?
}

struct CommentNode: Decodable, Sendable, Identifiable {
    struct UserNode: Decodable, Sendable {
        var id: String?
        var displayName: String?
        var avatarUrl: String?
    }
    var id: String?
    var body: String?
    var createdAt: Date?
    var url: String?
    var user: UserNode?
}

// MARK: - Mutation payloads

struct IssueUpdatePayload: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        var success: Bool?
        var issue: IssueNode?
    }
    var issueUpdate: Result
}

struct CommentCreatePayload: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct Created: Decodable, Sendable {
            var id: String?
            var url: String?
            var createdAt: Date?
        }
        var success: Bool?
        var comment: Created?
    }
    var commentCreate: Result
}
