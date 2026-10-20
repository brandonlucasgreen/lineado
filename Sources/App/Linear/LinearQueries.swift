import Foundation

/// The GraphQL documents, as string constants.
///
/// Kept in one file so the whole API surface the app touches is readable at a
/// glance — it is four queries and four mutations, and it should stay that
/// small (PLAN §2: not a Linear client).
enum LinearQueries {

    /// The fields every issue row needs. Shared so the list query and the
    /// mutation responses decode into the same `IssueNode`, which means a
    /// mutation's reply can update the row directly with no refetch.
    static let issueFields = """
        id
        identifier
        title
        url
        branchName
        priority
        priorityLabel
        dueDate
        createdAt
        updatedAt
        state { id name type color position }
        team { id key name }
        project { id name }
        projectMilestone { id name targetDate }
        labels { nodes { id name color } }
        parent { id identifier title }
        """

    /// Every open issue assigned to the authenticated user.
    ///
    /// Uses `viewer { assignedIssues }` rather than
    /// `issues(filter: { assignee: { isMe: ... } })`: `isMe` is not in Linear's
    /// published filter documentation (checked 2026-10-20), while
    /// `assignedIssues` is, takes the same `IssueFilter`, and removes the need
    /// to resolve and cache a viewer id first.
    ///
    /// All **three** terminal state types are excluded. `duplicate` is a real
    /// type distinct from `canceled` — verified against the live workspace,
    /// where Core UX has a "Duplicate" state typed `duplicate`. Omitting it
    /// leaves duplicates on the list forever.
    static let assignedIssues = """
        query AssignedIssues($after: String) {
          viewer {
            id
            name
            assignedIssues(
              first: 100
              after: $after
              filter: { state: { type: { nin: ["completed", "canceled", "duplicate"] } } }
              orderBy: updatedAt
            ) {
              pageInfo { hasNextPage endCursor }
              nodes { \(issueFields) }
            }
          }
        }
        """

    /// Every workflow state in the workspace, keyed by team.
    ///
    /// Fetched at launch and hourly. Not optional: `E` (complete) has to resolve
    /// the issue's *own team's* completed state, and the status picker can only
    /// offer states that belong to the selected issue's team.
    static let workflowStates = """
        query WorkflowStates($after: String) {
          workflowStates(first: 250, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id name type color position team { id key name } }
          }
        }
        """

    /// Description and recent comments, fetched when a row expands.
    ///
    /// On demand rather than on poll: one request for the row you are reading
    /// beats forty descriptions and several hundred comments every 60 seconds.
    static let issueDetail = """
        query IssueDetail($id: String!) {
          issue(id: $id) {
            id
            description
            comments(last: 20) {
              nodes {
                id
                body
                createdAt
                url
                user { id displayName avatarUrl }
              }
            }
          }
        }
        """

    // MARK: Mutations

    static let setState = """
        mutation SetState($id: String!, $stateId: String!) {
          issueUpdate(id: $id, input: { stateId: $stateId }) {
            success
            issue { \(issueFields) }
          }
        }
        """

    static let setPriority = """
        mutation SetPriority($id: String!, $priority: Int!) {
          issueUpdate(id: $id, input: { priority: $priority }) {
            success
            issue { \(issueFields) }
          }
        }
        """

    /// `$dueDate` is nullable on purpose: passing an explicit `null` clears the
    /// date. Omitting the variable would mean "leave unchanged" — see
    /// `JSONValue` for why this forced the variables type to change.
    static let setDueDate = """
        mutation SetDueDate($id: String!, $dueDate: TimelessDate) {
          issueUpdate(id: $id, input: { dueDate: $dueDate }) {
            success
            issue { \(issueFields) }
          }
        }
        """

    static let addComment = """
        mutation AddComment($id: String!, $body: String!) {
          commentCreate(input: { issueId: $id, body: $body }) {
            success
            comment { id url createdAt }
          }
        }
        """
}
