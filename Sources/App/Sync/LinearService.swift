import Foundation

/// The app's view of Linear: fetches, and the four writes.
///
/// Sits between `LinearClient` (transport) and `AppState` (UI), so neither has
/// to know about the other's vocabulary — `AppState` asks for issues and gets
/// `[Issue]`, never an `IssueNode`.
actor LinearService {
    private let client: LinearClient
    /// Stamped onto every issue this service returns, so a mutation can be
    /// routed back to the credential that is allowed to perform it.
    let workspaceID: String

    init(workspaceID: String, keychainAccount: String) {
        self.workspaceID = workspaceID
        self.client = LinearClient(keyProvider: { Keychain.get(keychainAccount) })
    }

    /// For tests and previews.
    init(workspaceID: String = "test", client: LinearClient) {
        self.workspaceID = workspaceID
        self.client = client
    }

    // MARK: Reads

    struct Snapshot: Sendable {
        var issues: [Issue]
        var viewerName: String
        /// What Linear calls this workspace. Fills in the name the user sees.
        var organizationName: String
        var organizationURLKey: String?
        /// Nodes Linear sent that could not become rows (PLAN: no silent drops).
        var dropped: Int
    }

    /// Every open assigned issue, paged to completion.
    ///
    /// **Pages to the end rather than taking the first 100.** A truncated task
    /// list is worse than a slow one: it hides work without ever saying so, and
    /// there is no badge or count that would look wrong.
    func fetchAssignedIssues() async throws -> Snapshot {
        var all: [IssueNode] = []
        var viewerName = ""
        var organizationName = ""
        var organizationURLKey: String?
        var cursor: String?
        var pages = 0

        repeat {
            let variables: [String: JSONValue] = cursor.map { ["after": .string($0)] } ?? [:]
            let payload: AssignedIssuesPayload = try await client.execute(
                LinearQueries.assignedIssues, variables: variables.isEmpty ? nil : variables)

            viewerName = payload.viewer.name ?? ""
            organizationName = payload.viewer.organization?.name ?? ""
            organizationURLKey = payload.viewer.organization?.urlKey
            all.append(contentsOf: payload.viewer.assignedIssues?.nodes ?? [])

            let info = payload.viewer.assignedIssues?.pageInfo
            cursor = (info?.hasNextPage ?? false) ? info?.endCursor : nil
            pages += 1
            // A cursor that never advances would spin forever. 20 pages is
            // 2,000 issues — far past anything a person is assigned.
            if pages >= 20 { break }
        } while cursor != nil

        var (issues, dropped) = LinearMapper.issues(from: all)
        // Stamped here rather than in the mapper: the mapper is pure and knows
        // nothing about which credential fetched these.
        for index in issues.indices { issues[index].workspaceID = workspaceID }
        if dropped > 0 {
            log.warning("Dropped \(dropped) issue node(s) with no team or no state")
        }
        return Snapshot(
            issues: issues, viewerName: viewerName,
            organizationName: organizationName, organizationURLKey: organizationURLKey,
            dropped: dropped)
    }

    /// Workflow states for the whole workspace, grouped by team.
    func fetchWorkflowStates() async throws -> [String: [WorkflowState]] {
        var all: [IssueNode.StateNode] = []
        var cursor: String?
        var pages = 0

        repeat {
            let variables: [String: JSONValue] = cursor.map { ["after": .string($0)] } ?? [:]
            let payload: WorkflowStatesPayload = try await client.execute(
                LinearQueries.workflowStates, variables: variables.isEmpty ? nil : variables)
            all.append(contentsOf: payload.workflowStates.nodes ?? [])
            let info = payload.workflowStates.pageInfo
            cursor = (info?.hasNextPage ?? false) ? info?.endCursor : nil
            pages += 1
            if pages >= 10 { break }
        } while cursor != nil

        return LinearMapper.statesByTeam(from: all)
    }

    func fetchDetail(issueID: String) async throws -> IssueDetail {
        let payload: IssueDetailPayload = try await client.execute(
            LinearQueries.issueDetail, variables: ["id": .string(issueID)])
        return IssueDetail(
            issueID: issueID,
            description: payload.issue?.description,
            comments: LinearMapper.comments(from: payload.issue?.comments?.nodes ?? []),
            fetchedAt: Date())
    }

    // MARK: Writes

    /// Each write returns the issue as Linear now has it, so the row can be
    /// reconciled from the mutation's own reply rather than waiting for a poll.
    @discardableResult
    func setState(issueID: String, stateID: String) async throws -> Issue? {
        let payload: IssueUpdatePayload = try await client.execute(
            LinearQueries.setState,
            variables: ["id": .string(issueID), "stateId": .string(stateID)])
        return try confirm(payload)
    }

    @discardableResult
    func setPriority(issueID: String, priority: Priority) async throws -> Issue? {
        let payload: IssueUpdatePayload = try await client.execute(
            LinearQueries.setPriority,
            variables: ["id": .string(issueID), "priority": .int(priority.rawValue)])
        return try confirm(payload)
    }

    /// `nil` clears the date — the request carries an explicit JSON null, which
    /// is why variables are `[String: JSONValue]` (see `JSONValue`).
    @discardableResult
    func setDueDate(issueID: String, dueDate: CalendarDate?) async throws -> Issue? {
        let payload: IssueUpdatePayload = try await client.execute(
            LinearQueries.setDueDate,
            variables: ["id": .string(issueID), "dueDate": JSONValue(dueDate?.wireValue)])
        return try confirm(payload)
    }

    func addComment(issueID: String, body: String) async throws {
        let payload: CommentCreatePayload = try await client.execute(
            LinearQueries.addComment,
            variables: ["id": .string(issueID), "body": .string(body)])
        guard payload.commentCreate.success == true else {
            throw LinearClient.Failure.graphQLErrors(["Linear refused the comment"])
        }
    }

    /// `success: false` with no GraphQL error is a real Linear response shape,
    /// and treating it as a win is how an optimistic update becomes a lie.
    private func confirm(_ payload: IssueUpdatePayload) throws -> Issue? {
        guard payload.issueUpdate.success == true else {
            throw LinearClient.Failure.graphQLErrors(["Linear refused the change"])
        }
        guard var issue = payload.issueUpdate.issue.flatMap(LinearMapper.issue(from:)) else {
            return nil
        }
        issue.workspaceID = workspaceID
        return issue
    }
}
