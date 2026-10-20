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
    /// Which workspaces have had their states fetched. Team ids are UUIDs and
    /// so unique across workspaces, which is why one flat `statesByTeam` is
    /// safe — but "have I fetched this workspace yet" still needs its own set.
    private var statesWorkspaces: Set<String> = []
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
    /// Which band of the panel the arrow keys act on.
    ///
    /// The filter chips are two stacked rows above a list, and all three want
    /// the arrow keys. Rather than give the chips their own shortcut, `↑` from
    /// the first row steps up into them and `↓` steps back down — so one pair
    /// of keys walks the whole panel top to bottom, which is what a Mac user
    /// tries first.
    enum FilterFocus: Equatable {
        case workspaces
        case teams
        case list
    }

    var filterFocus: FilterFocus = .list

    var selectionID: String?
    var expandedID: String?
    var searchText: String = ""
    var isSearchFocused = false

    private(set) var isSyncing = false
    private(set) var hasLoadedOnce = false
    /// The banner. Set by any failure, cleared by the next success.
    var errorMessage: String?

    // MARK: Collaborators

    let workspaces: WorkspaceStore
    /// One service per workspace, built lazily and cached by workspace id.
    private var services: [String: LinearService] = [:]
    /// Per-workspace failures, so one revoked key cannot blank the whole list.
    private(set) var workspaceErrors: [String: String] = [:]
    private var undoStack: [UndoableChange] = []
    private var isRecordingUndo = true
    private var syncTask: Task<Void, Never>?
    private var detailTasks: Set<String> = []

    init(workspaces: WorkspaceStore = WorkspaceStore()) {
        self.workspaces = workspaces
        if let cached = IssueCache.load() {
            issues = cached.issues
            lastSyncedAt = cached.savedAt
        }
    }

    // MARK: - Derived view model

    var criteria: FilterCriteria {
        FilterCriteria(
            workspaceID: preferences.workspaceID,
            teamID: preferences.teamID,
            showsBacklog: preferences.showsBacklog,
            searchText: searchText)
    }

    /// Chips are built from the list *before* the team filter runs — otherwise
    /// picking one chip would hide every other chip.
    var teamChips: [(team: Issue.Team, count: Int)] {
        // Honours the workspace filter but not the team one: picking a team
        // must not hide the other teams, while picking a workspace *should*
        // narrow which teams are offered — they belong to different accounts.
        let base = Ordering.filter(
            issues,
            criteria: FilterCriteria(workspaceID: preferences.workspaceID,
                                     teamID: nil,
                                     showsBacklog: preferences.showsBacklog,
                                     searchText: searchText),
            hiddenUntil: localState.hiddenUntil).visible
        return Ordering.teamChips(for: base)
    }

    var workspaceChips: [(id: String, name: String, count: Int)] {
        let base = Ordering.filter(
            issues,
            criteria: FilterCriteria(workspaceID: nil, teamID: nil,
                                     showsBacklog: preferences.showsBacklog,
                                     searchText: searchText),
            hiddenUntil: localState.hiddenUntil).visible
        return Ordering.workspaceChips(for: base, names: workspaceNames)
    }

    private var filtered: (visible: [Issue], hidden: HiddenCounts) {
        Ordering.filter(issues, criteria: criteria, hiddenUntil: localState.hiddenUntil)
    }

    var sections: [IssueSection] {
        Ordering.sections(
            for: filtered.visible,
            groupBy: preferences.groupBy,
            sortBy: preferences.sortBy,
            ascending: preferences.sortAscending,
            names: workspaceNames)
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

    var isConfigured: Bool { workspaces.hasAnyKey }

    /// The service that owns an issue — the only one whose credential can
    /// mutate it.
    func service(for workspaceID: String) -> LinearService? {
        guard let workspace = workspaces.workspace(id: workspaceID) else { return nil }
        if let existing = services[workspaceID] { return existing }
        let service = LinearService(
            workspaceID: workspace.id, keychainAccount: workspace.keychainAccount)
        services[workspaceID] = service
        return service
    }

    func service(for issue: Issue) -> LinearService? { service(for: issue.workspaceID) }

    /// Workspace id → display name, for group headers and chips.
    var workspaceNames: [String: String] {
        Dictionary(uniqueKeysWithValues: workspaces.workspaces.map { ($0.id, $0.name) })
    }

    var showsWorkspaceDimension: Bool { workspaces.enabled.count > 1 }

    // MARK: - Selection

    func selectFirstIfNeeded() {
        guard selectionID == nil || !orderedIssues.contains(where: { $0.id == selectionID }) else { return }
        selectionID = orderedIssues.first?.id
    }

    /// The bands that currently exist, top to bottom. The workspace row is
    /// absent with one workspace configured, so `↑` skips straight past it
    /// rather than landing on an invisible band.
    var focusBands: [FilterFocus] {
        showsWorkspaceDimension ? [.workspaces, .teams, .list] : [.teams, .list]
    }

    /// Moves focus one band up or down. Returns false at either end, so the
    /// caller can fall back to moving the selection.
    @discardableResult
    func moveFocus(_ offset: Int) -> Bool {
        let bands = focusBands
        guard let current = bands.firstIndex(of: filterFocus) else {
            filterFocus = .list
            return false
        }
        let next = current + offset
        guard bands.indices.contains(next) else { return false }
        filterFocus = bands[next]
        return true
    }

    /// `←`/`→` act on whichever band has focus — and from the list, on the
    /// **top-level** dimension (Brandon, 2026-10-20).
    ///
    /// With several workspaces that is the workspace: flipping accounts is the
    /// coarse move you want without leaving the list, and teams are reached by
    /// keying up into their row. With one workspace there is no workspace
    /// dimension, so teams *are* the top level and `←`/`→` cycles those —
    /// which keeps the keys useful rather than inert for the common case.
    func cycleFocusedFilter(by offset: Int) {
        switch filterFocus {
        case .workspaces:
            cycleWorkspace(by: offset)
        case .teams:
            cycleTeam(by: offset)
        case .list:
            if showsWorkspaceDimension { cycleWorkspace(by: offset) } else { cycleTeam(by: offset) }
        }
    }

    /// What `←`/`→` would cycle right now. Drives the hint bar, so the label
    /// and the behaviour cannot drift apart.
    var focusedFilterName: String {
        switch filterFocus {
        case .workspaces: "workspace"
        case .teams: "team"
        case .list: showsWorkspaceDimension ? "workspace" : "team"
        }
    }

    func cycleTeam(by offset: Int) {
        let ids: [String?] = [nil] + teamChips.map { $0.team.id }
        guard ids.count > 1 else { return }
        let current = ids.firstIndex(of: preferences.teamID) ?? 0
        preferences.teamID = ids[(current + offset + ids.count) % ids.count]
    }

    func cycleWorkspace(by offset: Int) {
        let ids: [String?] = [nil] + workspaceChips.map { $0.id }
        guard ids.count > 1 else { return }
        let current = ids.firstIndex(of: preferences.workspaceID) ?? 0
        preferences.workspaceID = ids[(current + offset + ids.count) % ids.count]
        // The team filter belonged to the workspace we just left.
        preferences.teamID = nil
    }

    var isSelectionAtTop: Bool {
        guard let selectionID, let first = orderedIssues.first else { return true }
        return first.id == selectionID
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

    /// Polls every enabled workspace and merges the results.
    ///
    /// **Each workspace succeeds or fails on its own.** A revoked key in one
    /// account must not blank the tasks from the others, so a failure is
    /// recorded against that workspace and its *previous* issues are kept
    /// rather than dropped. Only a workspace that answered contributes a fresh
    /// snapshot, and only its own rows are replaced.
    func refresh() async {
        guard isConfigured else {
            errorMessage = nil
            hasLoadedOnce = true
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false; hasLoadedOnce = true }

        let active = workspaces.enabled
        var freshIssues: [Issue] = []
        var answered: Set<String> = []

        for workspace in active {
            guard let service = service(for: workspace.id) else { continue }
            guard workspaces.hasKey(for: workspace.id) else {
                workspaceErrors[workspace.id] = "No API key yet."
                continue
            }

            // States first: without them `E` and the status picker are dead
            // keys for this workspace, and that should say so rather than look
            // like an empty list.
            if statesByTeam(hasAnyFor: workspace.id) == false {
                do {
                    let states = try await service.fetchWorkflowStates()
                    for (teamID, teamStates) in states { statesByTeam[teamID] = teamStates }
                    statesWorkspaces.insert(workspace.id)
                } catch {
                    workspaceErrors[workspace.id] = describe(error)
                    continue
                }
            }

            do {
                let snapshot = try await service.fetchAssignedIssues()
                freshIssues.append(contentsOf: snapshot.issues)
                answered.insert(workspace.id)
                viewerName = snapshot.viewerName
                workspaces.updateIdentity(
                    id: workspace.id,
                    name: snapshot.organizationName,
                    urlKey: snapshot.organizationURLKey)
                workspaceErrors.removeValue(forKey: workspace.id)
            } catch {
                workspaceErrors[workspace.id] = describe(error)
            }
        }

        // Rows from workspaces that did not answer are carried over untouched;
        // rows from ones no longer configured are dropped.
        let configured = Set(active.map(\.id))
        let carried = issues.filter {
            !answered.contains($0.workspaceID) && configured.contains($0.workspaceID)
        }
        merge(freshIssues + carried)

        if answered.isEmpty, !active.isEmpty {
            // Everything failed — that is worth a banner, where one failure is not.
            errorMessage = workspaceErrors.values.first
        } else {
            errorMessage = nil
            lastSyncedAt = Date()
            IssueCache.save(issues)
        }

        localState.prune(livingIssueIDs: Set(issues.map(\.id)))
        localState.save()
        selectFirstIfNeeded()
    }

    /// Whether the states cache has been filled for a workspace.
    private func statesByTeam(hasAnyFor workspaceID: String) -> Bool {
        statesWorkspaces.contains(workspaceID)
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
                guard let service = self.service(for: issue) else { return }
                let detail = try await service.fetchDetail(issueID: issue.id)
                self.details[issue.id] = detail
            } catch {
                self.rowErrors[issue.id] = self.describe(error)
            }
        }
    }
}
