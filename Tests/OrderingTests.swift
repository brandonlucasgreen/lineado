import Foundation
import Testing

@testable import Lineado

/// Swift Testing exports its own `Issue` type (the thing `#expect` records on
/// failure), which shadows ours in every test file. A module-scope alias in the
/// test target wins over the imported one, so the tests can keep saying `Issue`
/// and mean the app's.
typealias Issue = Lineado.Issue

// MARK: - Fixtures

enum Fixture {
    static func state(
        _ name: String, _ type: StateType, position: Double = 0, team: String = "core"
    ) -> WorkflowState {
        WorkflowState(id: "\(team).\(name)", name: name, type: type,
                      color: "#aabbcc", position: position, teamID: team)
    }

    static let core = Issue.Team(id: "core", key: "CORE", name: "Core UX")
    static let epd = Issue.Team(id: "epd", key: "EPD", name: "EPD")

    static func issue(
        _ identifier: String,
        priority: Priority = .none,
        due: CalendarDate? = nil,
        created: Date = Date(timeIntervalSince1970: 1_700_000_000),
        state: WorkflowState = Fixture.state("To Do", .unstarted, position: 2),
        team: Issue.Team = Fixture.core,
        project: Issue.Project? = nil,
        milestone: Issue.Milestone? = nil,
        labels: [Issue.Label] = []
    ) -> Issue {
        Issue(
            id: identifier, identifier: identifier, title: "Title of \(identifier)",
            url: "https://linear.app/x/issue/\(identifier)", branchName: "brandon/\(identifier.lowercased())",
            priority: priority, priorityLabel: nil, dueDate: due,
            createdAt: created, updatedAt: created,
            state: state, team: team, project: project, milestone: milestone,
            labels: labels, parent: nil, pendingUntil: nil)
    }
}

// MARK: - Priority

@Suite("Priority ordering")
struct PriorityOrderingTests {

    /// The single most load-bearing ordering fact in the app. Linear's raw
    /// scale is 0=None, 1=Urgent … 4=Low, so a naive ascending sort opens the
    /// list on every unprioritised issue — which is most of them.
    @Test("No priority sorts last, not first")
    func noPrioritySortsLast() {
        let issues = [
            Fixture.issue("A", priority: .none),
            Fixture.issue("B", priority: .urgent),
            Fixture.issue("C", priority: .low),
            Fixture.issue("D", priority: .high),
        ]
        let sorted = Ordering.sort(issues, by: .priority)
        #expect(sorted.map(\.identifier) == ["B", "D", "C", "A"])
    }

    @Test("Reversing priority still leaves No priority at the end it belongs")
    func reversedPriority() {
        let issues = [
            Fixture.issue("A", priority: .none),
            Fixture.issue("B", priority: .urgent),
            Fixture.issue("C", priority: .low),
        ]
        let sorted = Ordering.sort(issues, by: .priority, ascending: false)
        // Descending by rank: None (5) → Low (4) → Urgent (1).
        #expect(sorted.map(\.identifier) == ["A", "C", "B"])
    }

    @Test("Equal priorities fall back to identifier, so order is stable")
    func stableTieBreak() {
        let issues = [
            Fixture.issue("CORE-9", priority: .high),
            Fixture.issue("CORE-1", priority: .high),
            Fixture.issue("CORE-5", priority: .high),
        ]
        let once = Ordering.sort(issues, by: .priority).map(\.identifier)
        let twice = Ordering.sort(issues.reversed(), by: .priority).map(\.identifier)
        #expect(once == twice)
        #expect(once == ["CORE-1", "CORE-5", "CORE-9"])
    }

    @Test("sortRank maps every case exactly once")
    func sortRankIsATotalOrder() {
        let ranks = Priority.allCases.map(\.sortRank)
        #expect(Set(ranks).count == Priority.allCases.count)
        #expect(Priority.none.sortRank > Priority.low.sortRank)
    }
}

// MARK: - Due dates

@Suite("Due date ordering")
struct DueDateOrderingTests {

    /// Undated issues are the absence of a sort key, not an extreme value of
    /// one. Reversing a due-date sort should surface the furthest-out date, not
    /// promote forty undated issues to the top.
    @Test("Undated issues sort last in both directions")
    func undatedAlwaysLast() {
        let issues = [
            Fixture.issue("A", due: nil),
            Fixture.issue("B", due: CalendarDate(year: 2026, month: 11, day: 5)),
            Fixture.issue("C", due: CalendarDate(year: 2026, month: 10, day: 1)),
        ]
        #expect(Ordering.sort(issues, by: .dueDate).map(\.identifier) == ["C", "B", "A"])
        #expect(Ordering.sort(issues, by: .dueDate, ascending: false).map(\.identifier) == ["B", "C", "A"])
    }
}

// MARK: - Status grouping

@Suite("Status grouping")
struct StatusGroupingTests {

    /// Brandon, 2026-10-20: same-named states on different teams group
    /// separately. They are different records that each team configured, and
    /// folding them needed a cross-team ordering rule with no correct answer.
    @Test("Same status name on two teams makes two buckets")
    func sameNameTwoTeams() {
        let issues = [
            Fixture.issue("CORE-1", state: Fixture.state("To Do", .unstarted, team: "core"), team: Fixture.core),
            Fixture.issue("EPD-1", state: Fixture.state("To Do", .unstarted, team: "epd"), team: Fixture.epd),
        ]
        let sections = Ordering.sections(for: issues, groupBy: .status, sortBy: .priority)
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { $0.title == "To Do" })
        // Ambiguous names carry a team key so the two headers are tellable apart.
        #expect(sections.compactMap(\.subtitle).sorted() == ["CORE", "EPD"])
    }

    @Test("A unique status name carries no team suffix")
    func uniqueNameHasNoSuffix() {
        let issues = [
            Fixture.issue("CORE-1", state: Fixture.state("In Review", .started, team: "core")),
        ]
        let sections = Ordering.sections(for: issues, groupBy: .status, sortBy: .priority)
        #expect(sections.count == 1)
        #expect(sections[0].subtitle == nil)
    }

    /// Lifecycle first, then position — so Triage leads and Started trails
    /// however Linear's per-team `position` happens to be numbered.
    @Test("Buckets order by lifecycle, then position")
    func lifecycleOrder() {
        let issues = [
            Fixture.issue("A", state: Fixture.state("In Progress", .started, position: 1)),
            Fixture.issue("B", state: Fixture.state("Triage", .triage, position: 99)),
            Fixture.issue("C", state: Fixture.state("Backlog", .backlog, position: 50)),
            Fixture.issue("D", state: Fixture.state("To Do", .unstarted, position: 3)),
        ]
        let titles = Ordering.sections(for: issues, groupBy: .status, sortBy: .priority).map(\.title)
        #expect(titles == ["Triage", "Backlog", "To Do", "In Progress"])
    }

    @Test("Grouping is deterministic across input orderings")
    func deterministic() {
        let issues = [
            Fixture.issue("A", state: Fixture.state("To Do", .unstarted, position: 1, team: "core"), team: Fixture.core),
            Fixture.issue("B", state: Fixture.state("To Do", .unstarted, position: 1, team: "epd"), team: Fixture.epd),
            Fixture.issue("C", state: Fixture.state("Blocked", .backlog, position: 1, team: "core"), team: Fixture.core),
        ]
        let forward = Ordering.sections(for: issues, groupBy: .status, sortBy: .priority).map(\.id)
        let backward = Ordering.sections(for: issues.reversed(), groupBy: .status, sortBy: .priority).map(\.id)
        #expect(forward == backward)
    }
}

// MARK: - Project and milestone grouping

@Suite("Project and milestone grouping")
struct ProjectGroupingTests {

    @Test("The no-project bucket always trails, whatever it sorts like")
    func noProjectLast() {
        let issues = [
            Fixture.issue("A", project: nil),
            Fixture.issue("B", project: Issue.Project(id: "z", name: "Zebra")),
            Fixture.issue("C", project: Issue.Project(id: "a", name: "Alpha")),
        ]
        let titles = Ordering.sections(for: issues, groupBy: .project, sortBy: .priority).map(\.title)
        #expect(titles == ["Alpha", "Zebra", "No project"])
    }

    /// Brandon's workspace has a "GA" milestone under two different projects,
    /// which is why the header carries the project.
    @Test("Milestone headers carry their project")
    func milestoneCarriesProject() {
        let issues = [
            Fixture.issue("A",
                          project: Issue.Project(id: "p1", name: "Templates"),
                          milestone: Issue.Milestone(id: "m1", name: "GA", targetDate: nil)),
            Fixture.issue("B",
                          project: Issue.Project(id: "p2", name: "Saved Views"),
                          milestone: Issue.Milestone(id: "m2", name: "GA", targetDate: nil)),
        ]
        let sections = Ordering.sections(for: issues, groupBy: .milestone, sortBy: .priority)
        #expect(sections.count == 2)
        #expect(sections.map(\.subtitle) == ["Saved Views", "Templates"])
        #expect(sections.allSatisfy { $0.title == "GA" })
    }

    @Test("The no-milestone bucket trails")
    func noMilestoneLast() {
        let issues = [
            Fixture.issue("A", milestone: nil),
            Fixture.issue("B", project: Issue.Project(id: "p", name: "P"),
                          milestone: Issue.Milestone(id: "m", name: "Alpha", targetDate: nil)),
        ]
        let titles = Ordering.sections(for: issues, groupBy: .milestone, sortBy: .priority).map(\.title)
        #expect(titles == ["Alpha", "No milestone"])
    }
}

// MARK: - Filtering

@Suite("Filtering")
struct FilteringTests {

    /// Brandon, 2026-10-20: "I am fine with hiding backlog + hiding blocked
    /// being together." Linear types Blocked as `backlog`, so one toggle covers
    /// the pair — this test pins that it is a decision, not an accident.
    @Test("Hiding backlog also hides Blocked, which Linear types as backlog")
    func backlogTogglesBlocked() {
        let issues = [
            Fixture.issue("A", state: Fixture.state("Backlog", .backlog)),
            Fixture.issue("B", state: Fixture.state("Blocked", .backlog)),
            Fixture.issue("C", state: Fixture.state("To Do", .unstarted)),
        ]
        let hidden = Ordering.filter(issues, criteria: FilterCriteria(showsBacklog: false))
        #expect(hidden.visible.map(\.identifier) == ["C"])
        #expect(hidden.hidden.backlog == 2)

        let shown = Ordering.filter(issues, criteria: FilterCriteria(showsBacklog: true))
        #expect(shown.visible.count == 3)
        #expect(shown.hidden.isEmpty)
    }

    @Test("Each hidden issue is attributed to exactly one reason")
    func countsDoNotDoubleCount() {
        let issues = [
            Fixture.issue("A", state: Fixture.state("Backlog", .backlog), team: Fixture.epd),
            Fixture.issue("B", team: Fixture.epd),
            Fixture.issue("C"),
        ]
        let result = Ordering.filter(
            issues, criteria: FilterCriteria(teamID: "core", showsBacklog: false))
        #expect(result.visible.map(\.identifier) == ["C"])
        #expect(result.hidden.total == 2)
        #expect(result.hidden.backlog == 1)
        #expect(result.hidden.otherTeams == 1)
    }

    @Test("Locally hidden issues disappear until their date passes")
    func hideUntil() {
        let issues = [Fixture.issue("A"), Fixture.issue("B")]
        let now = Date()
        let result = Ordering.filter(
            issues,
            criteria: FilterCriteria(showsBacklog: true),
            hiddenUntil: ["A": now.addingTimeInterval(3600)],
            now: now)
        #expect(result.visible.map(\.identifier) == ["B"])
        #expect(result.hidden.snoozed == 1)

        let later = Ordering.filter(
            issues,
            criteria: FilterCriteria(showsBacklog: true),
            hiddenUntil: ["A": now.addingTimeInterval(-1)],
            now: now)
        #expect(later.visible.count == 2)
    }

    @Test("Search spans identifier, title, project, status, team and labels")
    func searchFields() {
        let issue = Fixture.issue(
            "CORE-1234",
            state: Fixture.state("In Review", .started),
            project: Issue.Project(id: "p", name: "Website Refresh"),
            labels: [Issue.Label(id: "l", name: "Landing Page", color: nil)])

        for needle in ["core-1234", "title of", "in review", "refresh", "landing page", "CORE", "Core UX"] {
            #expect(Ordering.matches(issue, needle: needle.lowercased()), "should match \(needle)")
        }
        #expect(!Ordering.matches(issue, needle: "nonsense"))
    }

    @Test("Team chips count what is visible under the other filters")
    func teamChips() {
        let issues = [
            Fixture.issue("A", team: Fixture.core),
            Fixture.issue("B", team: Fixture.core),
            Fixture.issue("C", team: Fixture.epd),
        ]
        let chips = Ordering.teamChips(for: issues)
        #expect(chips.map(\.team.key) == ["Core UX", "EPD"].map { $0 == "Core UX" ? "CORE" : "EPD" })
        #expect(chips.map(\.count) == [2, 1])
    }
}

// MARK: - Flattening

@Suite("Flattened order")
struct FlattenTests {

    /// Arrow keys walk the *rendered* order. Moving through the unsorted array
    /// instead is the bug every grouped list writes once.
    @Test("Flattened order matches what the eye reads")
    func flattenedFollowsSections() {
        let issues = [
            Fixture.issue("A", priority: .low, state: Fixture.state("In Progress", .started, position: 5)),
            Fixture.issue("B", priority: .urgent, state: Fixture.state("To Do", .unstarted, position: 1)),
            Fixture.issue("C", priority: .high, state: Fixture.state("In Progress", .started, position: 5)),
        ]
        let sections = Ordering.sections(for: issues, groupBy: .status, sortBy: .priority)
        let flat = Ordering.flattened(sections).map(\.identifier)
        #expect(flat == ["B", "C", "A"])
    }
}
