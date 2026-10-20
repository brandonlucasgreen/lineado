import Foundation
import Observation
import SwiftUI

/// The app's single source of truth for everything on screen.
///
/// `@MainActor` because every property here is read by a view. The network and
/// the pure ordering logic live elsewhere (`LinearService`, `Ordering`), which
/// keeps this file about *state transitions* rather than about Linear or sorting.
@MainActor
@Observable
final class AppState {

    // MARK: Data

    // These four are `internal` rather than `private(set)` because
    // `AppState+Mutations.swift` is logically part of this type and `private`
    // in Swift is file-scoped. The split is for readability — state transitions
    // here, the write path there — not an encapsulation boundary.
    var issues: [Issue] = []
    var details: [String: IssueDetail] = [:]
    var rowErrors: [String: String] = [:]
    private(set) var statesByTeam: [String: [WorkflowState]] = [:]
    private(set) var viewerName: String = ""
    private(set) var lastSyncedAt: Date?

    var localState: LocalState = .load()

    // MARK: Preferences

    var preferences: Preferences = .load() {
        didSet { if preferences != oldValue { preferences.save() } }
    }

    // MARK: Transient UI state

    /// The selected issue's id. Selection is by id, not index, so a poll that
    /// reorders the list does not move the cursor out from under you.
    var selectionID: String?
    var expandedID: String?
    var searchText: String = ""
    var isSearchFocused = false

    private(set) var isSyncing = false
    private(set) var hasLoadedOnce = false
    /// The banner. Set by any failure, cleared by the next success.
    var errorMessage: String?

    // MARK: Collaborators

    let linearService: LinearService
    private var undoStack: [UndoableChange] = []
    private var isRecordingUndo = true
    private var syncTask: Task<Void, Never>?
    private var detailTasks: Set<String> = []

    init(service: LinearService = LinearService()) {
        self.linearService = service
        if let cached = IssueCache.load() {
            issues = cached.issues
            lastSyncedAt = cached.savedAt
        }
    }

    // MARK: - Derived view model

    var criteria: FilterCriteria {
        FilterCriteria(
            teamID: preferences.teamID,
            showsBacklog: preferences.showsBacklog,
            searchText: searchText)
    }

    /// Chips are built from the list *before* the team filter runs — otherwise
    /// picking one chip would hide every other chip.
    var teamChips: [(team: Issue.Team, count: Int)] {
        let base = Ordering.filter(
            issues,
            criteria: FilterCriteria(teamID: nil,
                                     showsBacklog: preferences.showsBacklog,
                                     searchText: searchText),
            hiddenUntil: localState.hiddenUntil).visible
        return Ordering.teamChips(for: base)
    }

    private var filtered: (visible: [Issue], hidden: HiddenCounts) {
        Ordering.filter(issues, criteria: criteria, hiddenUntil: localState.hiddenUntil)
    }

    var sections: [IssueSection] {
        Ordering.sections(
            for: filtered.visible,
            groupBy: preferences.groupBy,
            sortBy: preferences.sortBy,
            ascending: preferences.sortAscending)
    }

    var hiddenCounts: HiddenCounts { filtered.hidden }

    /// The visible rows in the order the eye reads them. Arrow keys move
    /// through *this*, never through `issues`.
    var orderedIssues: [Issue] { Ordering.flattened(sections) }

    var selectedIssue: Issue? {
        guard let selectionID else { return nil }
        return issues.first { $0.id == selectionID }
    }

    /// The workflow states offered for an issue — its own team's, always.
    /// Statuses are per-team, so a workspace-wide list would offer states the
    /// mutation would reject.
    func availableStates(for issue: Issue) -> [WorkflowState] {
        statesByTeam[issue.team.id] ?? []
    }

    func completedState(for issue: Issue) -> WorkflowState? {
        availableStates(for: issue).first { $0.type == .completed }
    }

    func rowError(for id: String) -> String? { rowErrors[id] }
    func clearRowError(_ id: String) { rowErrors.removeValue(forKey: id) }
    func setRowError(_ id: String, _ message: String) { rowErrors[id] = message }

    // MARK: - Undo stack

    var undoStackTop: UndoableChange? { undoStack.last }

    /// Depth of 20: enough to walk back a flurry of priority changes, shallow
    /// enough that the oldest entry still describes an issue you remember.
    func record(_ change: UndoableChange) {
        guard isRecordingUndo else { return }
        undoStack.append(change)
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    func popUndo() -> UndoableChange? {
        undoStack.popLast()
    }

    /// Runs a verb without pushing its own undo entry, so undoing a change does
    /// not immediately become redoable-as-undo and trap `⌘Z` in a two-step loop.
    func applyWithoutRecording(_ work: () -> Void) {
        isRecordingUndo = false
        work()
        isRecordingUndo = true
    }

    /// A write that failed has already been rolled back, so its undo entry
    /// would put back a value that is already there — and, worse, hide the
    /// entry below it.
    func dropUndoEntries(for issueID: String) {
        undoStack.removeAll { $0.issueID == issueID }
    }

    func describeFailure(_ error: any Error) -> String { describe(error) }

    var isConfigured: Bool { Keychain.hasAPIKey() }

    // MARK: - Selection

    func selectFirstIfNeeded() {
        guard selectionID == nil || !orderedIssues.contains(where: { $0.id == selectionID }) else { return }
        selectionID = orderedIssues.first?.id
    }

    func moveSelection(by offset: Int) {
        let rows = orderedIssues
        guard !rows.isEmpty else { return }
        guard let current = selectionID, let index = rows.firstIndex(where: { $0.id == current }) else {
            selectionID = rows.first?.id
            return
        }
        let next = max(0, min(rows.count - 1, index + offset))
        selectionID = rows[next].id
    }

    /// `⌥↑` / `⌥↓` — to the first row of the previous or next group.
    func moveSelectionByGroup(_ offset: Int) {
        let groups = sections.filter { !$0.issues.isEmpty }
        guard !groups.isEmpty else { return }
        let currentGroup = groups.firstIndex { $0.issues.contains { $0.id == selectionID } } ?? 0
        let target = max(0, min(groups.count - 1, currentGroup + offset))
        selectionID = groups[target].issues.first?.id
    }

    // MARK: - Sync

    func start() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = await self?.preferences.pollInterval ?? 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    func refresh() async {
        guard isConfigured else {
            errorMessage = nil
            hasLoadedOnce = true
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false; hasLoadedOnce = true }

        // States first and separately: without them `E` and the status picker
        // are dead keys, and a states failure should say so rather than looking
        // like an empty issue list.
        if statesByTeam.isEmpty {
            do {
                statesByTeam = try await linearService.fetchWorkflowStates()
            } catch {
                errorMessage = describe(error)
                return
            }
        }

        do {
            let snapshot = try await linearService.fetchAssignedIssues()
            merge(snapshot.issues)
            viewerName = snapshot.viewerName
            lastSyncedAt = Date()
            errorMessage = nil
            IssueCache.save(issues)

            localState.prune(livingIssueIDs: Set(issues.map(\.id)))
            localState.save()
            selectFirstIfNeeded()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Replaces the list from a snapshot, **except** for issues with a mutation
    /// in flight.
    ///
    /// This guard is the whole reason `Issue.pendingUntil` exists. A 60s poll
    /// that started before your keystroke lands after it; without this the row
    /// visibly reverts a second after you changed it, and the change was
    /// actually fine. Same class of bug as Inbox & Chill's resurrect loop.
    private func merge(_ incoming: [Issue]) {
        let pending = Dictionary(
            uniqueKeysWithValues: issues.filter(\.isPending).map { ($0.id, $0) })

        issues = incoming.map { fresh in
            if let local = pending[fresh.id] { return local }
            return fresh
        }
    }

    func describe(_ error: any Error) -> String {
        (error as? LinearClient.Failure)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Detail

    func loadDetailIfNeeded(for issue: Issue) {
        if let existing = details[issue.id], existing.fetchedAt > issue.updatedAt { return }
        guard !detailTasks.contains(issue.id) else { return }
        detailTasks.insert(issue.id)

        Task { [weak self] in
            guard let self else { return }
            defer { self.detailTasks.remove(issue.id) }
            do {
                let detail = try await self.linearService.fetchDetail(issueID: issue.id)
                self.details[issue.id] = detail
            } catch {
                self.rowErrors[issue.id] = self.describe(error)
            }
        }
    }
}
