import Foundation

/// What `⌘Z` puts back.
///
/// Holds the **whole prior value**, not a diff, because undo is an inverse
/// mutation sent to Linear and can itself fail — it needs enough to rebuild the
/// request from scratch, not just enough to patch a local struct.
enum UndoableChange: Sendable {
    case state(issueID: String, previous: WorkflowState, label: String)
    case priority(issueID: String, previous: Priority, label: String)
    case dueDate(issueID: String, previous: CalendarDate?, label: String)
    case hidden(issueID: String, label: String)

    var issueID: String {
        switch self {
        case .state(let id, _, _), .priority(let id, _, _),
             .dueDate(let id, _, _), .hidden(let id, _):
            id
        }
    }

    var label: String {
        switch self {
        case .state(_, _, let label), .priority(_, _, let label),
             .dueDate(_, _, let label), .hidden(_, let label):
            label
        }
    }
}

extension AppState {

    /// How long after a write a poll keeps its hands off this issue.
    ///
    /// Long enough to cover the request plus the poll that was already in
    /// flight when it started; short enough that a genuine remote change shows
    /// up on the following cycle.
    private static let pendingGrace: TimeInterval = 15

    // MARK: - The four verbs

    func setState(_ issue: Issue, to state: WorkflowState) {
        let previous = issue.state
        apply(to: issue.id) { $0.state = state }
        record(.state(issueID: issue.id, previous: previous,
                      label: "Status to \(state.name)"))

        perform(issue.id, revert: { $0.state = previous }) { service in
            try await service.setState(issueID: issue.id, stateID: state.id)
        }
    }

    func setPriority(_ issue: Issue, to priority: Priority) {
        let previous = issue.priority
        let previousLabel = issue.priorityLabel
        apply(to: issue.id) {
            $0.priority = priority
            // Clear the server's label so the row falls back to our own until
            // the mutation's reply supplies Linear's. Leaving the old label in
            // place would show "Urgent" next to a Low-priority bar.
            $0.priorityLabel = nil
        }
        record(.priority(issueID: issue.id, previous: previous,
                         label: "Priority to \(priority.fallbackLabel)"))

        perform(issue.id, revert: { $0.priority = previous; $0.priorityLabel = previousLabel }) { service in
            try await service.setPriority(issueID: issue.id, priority: priority)
        }
    }

    func setDueDate(_ issue: Issue, to date: CalendarDate?) {
        let previous = issue.dueDate
        apply(to: issue.id) { $0.dueDate = date }
        record(.dueDate(issueID: issue.id, previous: previous,
                        label: date == nil ? "Cleared due date" : "Due \(date!.wireValue)"))

        perform(issue.id, revert: { $0.dueDate = previous }) { service in
            try await service.setDueDate(issueID: issue.id, dueDate: date)
        }
    }

    /// `E`. Resolves the issue's **own team's** completed state.
    ///
    /// If the states cache is cold this says so rather than quietly doing
    /// nothing — a dead key that looks alive is worse than an error.
    func complete(_ issue: Issue) {
        guard let done = completedState(for: issue) else {
            setRowError(issue.id, "No completed status for \(issue.team.key) yet — still loading statuses.")
            return
        }
        setState(issue, to: done)
    }

    /// Posting a comment is **not** optimistic and **not** undoable.
    ///
    /// Not optimistic because a comment is visible to the team the moment it
    /// lands, so showing it before it has is a lie with an audience. Not
    /// undoable because `⌘Z` deleting a teammate-visible comment behind a
    /// familiar shortcut is a different act than reverting a field.
    func postComment(on issue: Issue, body: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await linearService.addComment(issueID: issue.id, body: trimmed)
            details.removeValue(forKey: issue.id)
            loadDetailIfNeeded(for: issue)
            return true
        } catch {
            setRowError(issue.id, describeFailure(error))
            return false
        }
    }

    // MARK: - Hide until (local only)

    func hide(_ issue: Issue, until date: Date) {
        localState.hiddenUntil[issue.id] = date
        localState.save()
        record(.hidden(issueID: issue.id, label: "Hid \(issue.identifier)"))
        moveSelectionAfterRemoval(of: issue.id)
    }

    func unhide(_ issueID: String) {
        localState.hiddenUntil.removeValue(forKey: issueID)
        localState.save()
    }

    // MARK: - Undo

    var undoLabel: String? { undoStackTop?.label }

    func undoLastChange() {
        guard let change = popUndo() else { return }
        guard let issue = issues.first(where: { $0.id == change.issueID }) else { return }

        switch change {
        case .state(_, let previous, _):
            // Re-enter through the normal verb so the inverse is itself
            // optimistic, guarded and reversible.
            applyWithoutRecording { setState(issue, to: previous) }
        case .priority(_, let previous, _):
            applyWithoutRecording { setPriority(issue, to: previous) }
        case .dueDate(_, let previous, _):
            applyWithoutRecording { setDueDate(issue, to: previous) }
        case .hidden(let id, _):
            unhide(id)
            selectionID = id
        }
    }

    // MARK: - Plumbing

    private func apply(to id: String, _ change: (inout Issue) -> Void) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        change(&issues[index])
        issues[index].pendingUntil = Date().addingTimeInterval(Self.pendingGrace)
        clearRowError(id)
    }

    /// Fires the request, and on failure puts the row back exactly as it was.
    ///
    /// Nothing is ever dropped silently: a failed write reverts *and* leaves an
    /// inline error on the row. (Inbox & Chill's rule 5 — silent failure is this
    /// project's recurring bug class.)
    private func perform(
        _ id: String,
        revert: @escaping (inout Issue) -> Void,
        _ work: @escaping @Sendable (LinearService) async throws -> Issue?
    ) {
        let service = linearService
        Task { [weak self] in
            guard let self else { return }
            do {
                let confirmed = try await work(service)
                // Reconcile from the mutation's own reply rather than waiting
                // for the next poll, so the row shows Linear's truth — its new
                // priorityLabel, its new updatedAt — within the same second.
                if let confirmed, let index = self.issues.firstIndex(where: { $0.id == id }) {
                    var merged = confirmed
                    merged.pendingUntil = nil
                    self.issues[index] = merged
                } else {
                    self.clearPending(id)
                }
            } catch {
                self.rollback(id, revert)
                self.setRowError(id, self.describeFailure(error))
                self.dropUndoEntries(for: id)
            }
        }
    }

    private func rollback(_ id: String, _ revert: (inout Issue) -> Void) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        revert(&issues[index])
        issues[index].pendingUntil = nil
    }

    private func clearPending(_ id: String) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        issues[index].pendingUntil = nil
    }

    /// Keeps the cursor somewhere sensible when the selected row leaves.
    private func moveSelectionAfterRemoval(of id: String) {
        guard selectionID == id else { return }
        let rows = orderedIssues
        selectionID = rows.first(where: { $0.id != id })?.id
    }
}
