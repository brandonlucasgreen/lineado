import Foundation

// MARK: - The two axes

/// What the list is grouped into.
enum GroupBy: String, Sendable, CaseIterable, Codable, Identifiable {
    case none, priority, status, project, milestone, team
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Nothing"
        case .priority: "Priority"
        case .status: "Status"
        case .project: "Project"
        case .milestone: "Milestone"
        case .team: "Team"
        }
    }
}

/// How rows are ordered inside a group.
enum SortBy: String, Sendable, CaseIterable, Codable, Identifiable {
    case priority, dueDate, created, updated, team
    var id: String { rawValue }

    var label: String {
        switch self {
        case .priority: "Priority"
        case .dueDate: "Due Date"
        case .created: "Created"
        case .updated: "Updated"
        case .team: "Team"
        }
    }
}

// MARK: - Filtering

/// Everything that decides whether an issue is on screen.
///
/// The three filters compose rather than override: a team chip, the Backlog
/// toggle and the search text all narrow the same list, and the footer reports
/// each one's contribution so the list never silently lies about its size.
struct FilterCriteria: Sendable, Equatable {
    /// Nil means every team.
    var teamID: String?
    var showsBacklog: Bool = false
    var searchText: String = ""

    static let `default` = FilterCriteria()
}

/// Why an issue is not on screen. Drives the footer's "N hidden" accounting.
struct HiddenCounts: Sendable, Equatable {
    var backlog = 0
    var otherTeams = 0
    var snoozed = 0
    var search = 0

    var total: Int { backlog + otherTeams + snoozed + search }
    var isEmpty: Bool { total == 0 }
}

// MARK: - A section of the list

struct IssueSection: Identifiable, Sendable, Equatable {
    /// Stable across refreshes, so SwiftUI keeps scroll position and expansion.
    let id: String
    /// What the header reads. Empty for the single section of an ungrouped list.
    let title: String
    /// A `Project › Milestone` header's leading half, or a disambiguating team
    /// key. Rendered dimmer than the title.
    let subtitle: String?
    var issues: [Issue]
}

// MARK: - The pure engine

/// Grouping, sorting and filtering, as pure functions over values.
///
/// Every method is `nonisolated static` and takes everything it needs as an
/// argument — no app state, no clock, no calendar of its own. That is what
/// makes the ordering rules testable without a window, which is the one habit
/// that kept Inbox & Chill's selection arithmetic from ever being the bug.
enum Ordering {

    // MARK: Filter

    /// Applies the team chip, the Backlog toggle, local hide-until and the
    /// search text, and reports what each one removed.
    nonisolated static func filter(
        _ issues: [Issue],
        criteria: FilterCriteria,
        hiddenUntil: [String: Date] = [:],
        now: Date = Date()
    ) -> (visible: [Issue], hidden: HiddenCounts) {
        var counts = HiddenCounts()
        let needle = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let visible = issues.filter { issue in
            // Order matters only for the accounting: each issue is attributed
            // to the first reason it is off screen, so the counts sum to the
            // number actually hidden rather than double-counting.
            if let until = hiddenUntil[issue.id], until > now {
                counts.snoozed += 1
                return false
            }
            if !criteria.showsBacklog, issue.state.type.isBacklog {
                counts.backlog += 1
                return false
            }
            if let teamID = criteria.teamID, issue.team.id != teamID {
                counts.otherTeams += 1
                return false
            }
            if !needle.isEmpty, !matches(issue, needle: needle) {
                counts.search += 1
                return false
            }
            return true
        }
        return (visible, counts)
    }

    /// Substring match across the fields you would actually type: the short
    /// code, the title, and the names of the things it is filed under.
    nonisolated static func matches(_ issue: Issue, needle: String) -> Bool {
        if issue.identifier.lowercased().contains(needle) { return true }
        if issue.title.lowercased().contains(needle) { return true }
        if issue.state.name.lowercased().contains(needle) { return true }
        if issue.team.name.lowercased().contains(needle) { return true }
        if issue.team.key.lowercased().contains(needle) { return true }
        if let project = issue.project, project.name.lowercased().contains(needle) { return true }
        if let milestone = issue.milestone, milestone.name.lowercased().contains(needle) { return true }
        if issue.labels.contains(where: { $0.name.lowercased().contains(needle) }) { return true }
        return false
    }

    // MARK: Sort

    nonisolated static func sort(
        _ issues: [Issue], by sortBy: SortBy, ascending: Bool = true
    ) -> [Issue] {
        // Issues with no sort key are partitioned out *before* the direction is
        // applied, not sorted with a sentinel value.
        //
        // The obvious implementation — a comparator that reports "nil is
        // greater" — breaks the moment you reverse it: flipping the comparison
        // flips the nils to the front too, so a descending due-date sort opens
        // on forty undated issues. "No date" is the absence of a sort key, not
        // an extreme value of one, so it belongs outside the ordering.
        let (keyed, unkeyed) = partition(issues, by: sortBy)

        let sorted = keyed.sorted { lhs, rhs in
            let order = compare(lhs, rhs, by: sortBy)
            // A pure tie falls through to the identifier so the order is
            // deterministic — two runs over the same data never differ, which
            // matters because the list is rebuilt on every 60s poll.
            if order == .orderedSame {
                return lhs.identifier < rhs.identifier
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return sorted + unkeyed.sorted { $0.identifier < $1.identifier }
    }

    /// Splits off the issues that have nothing to sort by on this axis.
    ///
    /// Only due date can be absent today; priority has an explicit "No
    /// priority" level that is a real value with a real rank, and the dates and
    /// team are always present.
    private nonisolated static func partition(
        _ issues: [Issue], by sortBy: SortBy
    ) -> (keyed: [Issue], unkeyed: [Issue]) {
        guard sortBy == .dueDate else { return (issues, []) }
        var keyed: [Issue] = []
        var unkeyed: [Issue] = []
        for issue in issues {
            if issue.dueDate == nil { unkeyed.append(issue) } else { keyed.append(issue) }
        }
        return (keyed, unkeyed)
    }

    nonisolated static func compare(_ lhs: Issue, _ rhs: Issue, by sortBy: SortBy) -> ComparisonResult {
        switch sortBy {
        case .priority:
            return compareInts(lhs.priority.sortRank, rhs.priority.sortRank)
        case .dueDate:
            return compareOptionalLast(lhs.dueDate, rhs.dueDate)
        case .created:
            return compareDates(lhs.createdAt, rhs.createdAt)
        case .updated:
            return compareDates(lhs.updatedAt, rhs.updatedAt)
        case .team:
            return compareStrings(lhs.team.key, rhs.team.key)
        }
    }

    // MARK: Group

    /// The whole pipeline: filter, then group, then sort inside each group.
    nonisolated static func sections(
        for issues: [Issue],
        groupBy: GroupBy,
        sortBy: SortBy,
        ascending: Bool = true
    ) -> [IssueSection] {
        switch groupBy {
        case .none:
            return [IssueSection(id: "all", title: "", subtitle: nil,
                                 issues: sort(issues, by: sortBy, ascending: ascending))]
        case .priority:
            return groupByPriority(issues, sortBy: sortBy, ascending: ascending)
        case .status:
            return groupByStatus(issues, sortBy: sortBy, ascending: ascending)
        case .project:
            return groupByProject(issues, sortBy: sortBy, ascending: ascending)
        case .milestone:
            return groupByMilestone(issues, sortBy: sortBy, ascending: ascending)
        case .team:
            return groupByTeam(issues, sortBy: sortBy, ascending: ascending)
        }
    }

    private nonisolated static func groupByPriority(
        _ issues: [Issue], sortBy: SortBy, ascending: Bool
    ) -> [IssueSection] {
        let buckets = Dictionary(grouping: issues, by: \.priority)
        return buckets.keys
            .sorted { $0.sortRank < $1.sortRank }
            .map { priority in
                let rows = buckets[priority] ?? []
                return IssueSection(
                    id: "priority.\(priority.rawValue)",
                    title: rows.first?.priorityLabel ?? priority.fallbackLabel,
                    subtitle: nil,
                    issues: sort(rows, by: sortBy, ascending: ascending))
            }
    }

    /// Status buckets are keyed by **state id, not state name**.
    ///
    /// Two teams' "To Do" are two different records that each team configured,
    /// so they group separately (PLAN §5.2, Brandon 2026-10-20). Folding by name
    /// was cut: it needed a cross-team ordering rule with no correct answer, and
    /// it merged states whose meanings diverge.
    ///
    /// Order is `type` lifecycle, then `position` within the team, then team key,
    /// then name — the last two only to break ties, so two teams' states never
    /// land in an order that depends on dictionary iteration.
    private nonisolated static func groupByStatus(
        _ issues: [Issue], sortBy: SortBy, ascending: Bool
    ) -> [IssueSection] {
        let buckets = Dictionary(grouping: issues, by: \.state.id)

        let ordered = buckets.values
            .compactMap { rows -> (state: WorkflowState, team: Issue.Team, rows: [Issue])? in
                guard let first = rows.first else { return nil }
                return (first.state, first.team, rows)
            }
            .sorted { lhs, rhs in
                if lhs.state.type.lifecycleRank != rhs.state.type.lifecycleRank {
                    return lhs.state.type.lifecycleRank < rhs.state.type.lifecycleRank
                }
                if lhs.state.position != rhs.state.position {
                    return lhs.state.position < rhs.state.position
                }
                if lhs.team.key != rhs.team.key { return lhs.team.key < rhs.team.key }
                return lhs.state.name < rhs.state.name
            }

        // A team suffix is noise when the name is already unique on screen, and
        // essential when it is not — so it is decided per render, over the
        // buckets that actually exist, not baked into the name.
        let nameCounts = ordered.reduce(into: [String: Int]()) { counts, bucket in
            counts[bucket.state.name, default: 0] += 1
        }

        return ordered.map { bucket in
            IssueSection(
                id: "status.\(bucket.state.id)",
                title: bucket.state.name,
                subtitle: (nameCounts[bucket.state.name] ?? 0) > 1 ? bucket.team.key : nil,
                issues: sort(bucket.rows, by: sortBy, ascending: ascending))
        }
    }

    private nonisolated static func groupByProject(
        _ issues: [Issue], sortBy: SortBy, ascending: Bool
    ) -> [IssueSection] {
        let buckets = Dictionary(grouping: issues) { $0.project?.id ?? noneKey }
        return buckets
            .map { key, rows in
                (key: key, name: rows.first?.project?.name ?? "No project", rows: rows)
            }
            .sorted { lhs, rhs in
                // The "no project" bucket always trails, however it sorts
                // alphabetically — it is the absence of a group, not a group.
                if lhs.key == noneKey { return false }
                if rhs.key == noneKey { return true }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { bucket in
                IssueSection(
                    id: "project.\(bucket.key)",
                    title: bucket.name,
                    subtitle: nil,
                    issues: sort(bucket.rows, by: sortBy, ascending: ascending))
            }
    }

    /// A milestone name ("GA", "QA & Bugs", "Planning") is meaningless without
    /// its project — Brandon's workspace has a "GA" milestone under two
    /// different projects — so the header reads `Project › Milestone`.
    private nonisolated static func groupByMilestone(
        _ issues: [Issue], sortBy: SortBy, ascending: Bool
    ) -> [IssueSection] {
        let buckets = Dictionary(grouping: issues) { $0.milestone?.id ?? noneKey }
        return buckets
            .map { key, rows -> (key: String, project: String?, name: String, rows: [Issue]) in
                guard let milestone = rows.first?.milestone else {
                    return (noneKey, nil, "No milestone", rows)
                }
                return (key, rows.first?.project?.name, milestone.name, rows)
            }
            .sorted { lhs, rhs in
                if lhs.key == noneKey { return false }
                if rhs.key == noneKey { return true }
                let lp = lhs.project ?? ""
                let rp = rhs.project ?? ""
                if lp != rp { return lp.localizedCaseInsensitiveCompare(rp) == .orderedAscending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { bucket in
                IssueSection(
                    id: "milestone.\(bucket.key)",
                    title: bucket.name,
                    subtitle: bucket.project,
                    issues: sort(bucket.rows, by: sortBy, ascending: ascending))
            }
    }

    private nonisolated static func groupByTeam(
        _ issues: [Issue], sortBy: SortBy, ascending: Bool
    ) -> [IssueSection] {
        let buckets = Dictionary(grouping: issues, by: \.team.id)
        return buckets.values
            .compactMap { rows -> (team: Issue.Team, rows: [Issue])? in
                guard let team = rows.first?.team else { return nil }
                return (team, rows)
            }
            .sorted { $0.team.name.localizedCaseInsensitiveCompare($1.team.name) == .orderedAscending }
            .map { bucket in
                IssueSection(
                    id: "team.\(bucket.team.id)",
                    title: bucket.team.name,
                    subtitle: bucket.team.key,
                    issues: sort(bucket.rows, by: sortBy, ascending: ascending))
            }
    }

    private static let noneKey = "\u{0}none"

    // MARK: Team chips

    /// The filter bar's chips: every team that has a visible issue, with its
    /// count, in a stable order. Built from the list *before* the team filter
    /// is applied, or selecting one chip would hide all the others.
    nonisolated static func teamChips(for issues: [Issue]) -> [(team: Issue.Team, count: Int)] {
        Dictionary(grouping: issues, by: \.team.id).values
            .compactMap { rows in rows.first.map { ($0.team, rows.count) } }
            .sorted { $0.team.name.localizedCaseInsensitiveCompare($1.team.name) == .orderedAscending }
    }

    // MARK: Flat order, for ↑/↓

    /// The sections flattened back into the order the eye reads them.
    ///
    /// Selection moves through *this*, not through the unsorted array — which
    /// is the bug that keeps being written when a grouped list grows arrow keys.
    nonisolated static func flattened(_ sections: [IssueSection]) -> [Issue] {
        sections.flatMap(\.issues)
    }
}

// MARK: - Comparator helpers

/// Compares two optionals that `Ordering.partition` has already guaranteed are
/// both non-nil. The nil cases remain for totality and are unreachable from
/// `sort` — absence is handled by partitioning, not by this comparator.
private func compareOptionalLast<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
    switch (lhs, rhs) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case let (l?, r?): return l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
    }
}

private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
    lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
}

private func compareDates(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
    lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
}

private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.localizedCaseInsensitiveCompare(rhs)
}
