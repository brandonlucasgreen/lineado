import Foundation

/// Wire types → domain types.
///
/// Pure and `nonisolated`, so the whole translation is testable against a
/// recorded payload with no network, no actor and no app state — Inbox & Chill's
/// rule 6, and the reason a mapping bug there is always caught by a test rather
/// than by a user.
enum LinearMapper {

    /// Drops any node that cannot become a usable row rather than substituting
    /// placeholder values.
    ///
    /// An issue with no team cannot have its status changed (statuses are
    /// per-team) and cannot be completed, so a row for it would be a row with
    /// dead keys. `dropped` is surfaced in diagnostics rather than swallowed —
    /// silently returning fewer issues than Linear sent is exactly the kind of
    /// quiet failure that hides for months.
    nonisolated static func issues(from nodes: [IssueNode]) -> (issues: [Issue], dropped: Int) {
        var mapped: [Issue] = []
        var dropped = 0
        for node in nodes {
            if let issue = issue(from: node) {
                mapped.append(issue)
            } else {
                dropped += 1
            }
        }
        return (mapped, dropped)
    }

    nonisolated static func issue(from node: IssueNode) -> Issue? {
        // An id, a state and a team are the three things a row cannot be built
        // without: no team means no status picker and no completed state, so
        // its keys would be dead.
        guard let id = node.id, !id.isEmpty,
              let stateNode = node.state,
              let teamNode = node.team, let teamID = teamNode.id
        else { return nil }

        return Issue(
            id: id,
            identifier: node.identifier ?? "",
            title: (node.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            url: node.url ?? "",
            branchName: node.branchName,
            // An unrecognised priority becomes "No priority" rather than
            // failing the row — Linear could extend the scale.
            priority: Priority(rawValue: node.priority ?? 0) ?? .none,
            priorityLabel: node.priorityLabel,
            dueDate: node.dueDate.flatMap(CalendarDate.init(wireValue:)),
            createdAt: node.createdAt ?? .distantPast,
            updatedAt: node.updatedAt ?? .distantPast,
            state: workflowState(from: stateNode),
            team: Issue.Team(id: teamID, key: teamNode.key ?? "", name: teamNode.name ?? ""),
            project: node.project.flatMap { project in
                project.id.map { Issue.Project(id: $0, name: project.name ?? "") }
            },
            milestone: node.projectMilestone.flatMap { milestone in
                milestone.id.map {
                    Issue.Milestone(
                        id: $0,
                        name: milestone.name ?? "",
                        targetDate: milestone.targetDate.flatMap(CalendarDate.init(wireValue:)))
                }
            },
            labels: (node.labels?.nodes ?? []).compactMap { label in
                label.id.map { Issue.Label(id: $0, name: label.name ?? "", color: label.color) }
            },
            parent: node.parent.flatMap { parent in
                parent.id.map {
                    Issue.ParentRef(id: $0, identifier: parent.identifier ?? "",
                                    title: parent.title ?? "")
                }
            },
            pendingUntil: nil)
    }

    nonisolated static func workflowState(from node: IssueNode.StateNode) -> WorkflowState {
        WorkflowState(
            id: node.id ?? "",
            name: node.name ?? "",
            type: StateType(wireValue: node.type ?? ""),
            color: node.color,
            position: node.position ?? 0,
            teamID: node.team?.id)
    }

    /// The states cache, grouped by team id.
    ///
    /// A state with no team is dropped: it cannot be offered in a picker,
    /// because a picker is always scoped to one issue's team.
    nonisolated static func statesByTeam(
        from nodes: [IssueNode.StateNode]
    ) -> [String: [WorkflowState]] {
        var result: [String: [WorkflowState]] = [:]
        for node in nodes {
            guard let teamID = node.team?.id else { continue }
            result[teamID, default: []].append(workflowState(from: node))
        }
        // Picker order is Linear's own order within the team, which is what the
        // user sees in Linear itself.
        for key in result.keys {
            result[key]?.sort { lhs, rhs in
                if lhs.type.lifecycleRank != rhs.type.lifecycleRank {
                    return lhs.type.lifecycleRank < rhs.type.lifecycleRank
                }
                return lhs.position < rhs.position
            }
        }
        return result
    }

    nonisolated static func comments(from nodes: [CommentNode]) -> [IssueComment] {
        nodes
            .compactMap { node -> IssueComment? in
                guard let id = node.id, !id.isEmpty else { return nil }
                return IssueComment(
                    id: id,
                    body: node.body ?? "",
                    authorName: node.user?.displayName ?? "Unknown",
                    avatarURL: node.user?.avatarUrl.flatMap(URL.init(string:)),
                    createdAt: node.createdAt ?? .distantPast,
                    url: node.url.flatMap(URL.init(string:)))
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

// MARK: - Detail

/// An issue's description and comments, fetched on expand and cached until the
/// next poll touches that issue.
struct IssueDetail: Sendable, Equatable {
    let issueID: String
    var description: String?
    var comments: [IssueComment]
    var fetchedAt: Date
}

struct IssueComment: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let authorName: String
    let avatarURL: URL?
    let createdAt: Date
    let url: URL?
}
