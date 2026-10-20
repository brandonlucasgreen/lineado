import Foundation

/// One Linear issue assigned to you.
///
/// A value type, not a database record: Linear owns this data and Lineado only
/// mirrors it (PLAN §4.2). The only locally-authored state in the whole app is
/// `LocalState.hiddenUntil`, which is keyed by `id` and stored separately so a
/// poll can replace this struct wholesale without losing it.
struct Issue: Identifiable, Sendable, Hashable, Codable {
    /// Linear's UUID. The identity used for mutations, local state and caching.
    let id: String
    /// The human-facing short code, `CORE-1234`.
    let identifier: String
    var title: String
    let url: String
    /// Linear's suggested git branch name, for `⌘⇧C`.
    let branchName: String?

    var priority: Priority
    /// Linear's own phrasing for `priority` ("Urgent", "Medium").
    ///
    /// Displayed in preference to a local table so that a rename on Linear's
    /// side cannot make the app lie. Inbox & Chill's `LinearGraphQL.swift`
    /// calls priority 3 "normal"; Linear itself calls it "Medium".
    var priorityLabel: String?

    /// Date-only, as Linear's `TimelessDate` scalar: `2026-11-05`.
    var dueDate: CalendarDate?
    let createdAt: Date
    var updatedAt: Date

    var state: WorkflowState
    let team: Team
    var project: Project?
    var milestone: Milestone?
    var labels: [Label]
    /// Set on a sub-issue. Shown as a chip, not as a tree (PLAN §9).
    let parent: ParentRef?

    /// Set while a mutation is in flight, and for a grace period after.
    ///
    /// A poll that started before your keystroke lands after it, and without
    /// this would visibly revert the change. The merge skips remote fields for
    /// issues whose `pendingUntil` is in the future (PLAN §4.7).
    ///
    /// Not persisted — a relaunch has no in-flight mutations by definition.
    var pendingUntil: Date?

    var isPending: Bool {
        guard let pendingUntil else { return false }
        return pendingUntil > Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, identifier, title, url, branchName, priority, priorityLabel
        case dueDate, createdAt, updatedAt, state, team, project, milestone
        case labels, parent
    }
}

// MARK: - Nested value types

extension Issue {
    struct Team: Sendable, Hashable, Codable, Identifiable {
        let id: String
        /// `CORE`, `EPD`. Used to disambiguate same-named statuses.
        let key: String
        let name: String
    }

    struct Project: Sendable, Hashable, Codable, Identifiable {
        let id: String
        let name: String
    }

    /// A milestone belongs to a project, and its name ("GA", "QA & Bugs") is
    /// meaningless without one — Brandon's workspace has a "GA" milestone under
    /// two different projects. Group headers read `Project › Milestone`.
    struct Milestone: Sendable, Hashable, Codable, Identifiable {
        let id: String
        let name: String
        let targetDate: CalendarDate?
    }

    struct Label: Sendable, Hashable, Codable, Identifiable {
        let id: String
        let name: String
        /// Hex like `#f2c94c`, drawn as the chip's dot.
        let color: String?
    }

    struct ParentRef: Sendable, Hashable, Codable {
        let id: String
        let identifier: String
        let title: String
    }
}

// MARK: - Priority

/// Linear's five-level priority.
///
/// The raw values are Linear's and cannot be reordered. `sortRank` exists
/// precisely because they are in the wrong order for sorting: raw ascending
/// puts "No priority" first, and no-priority is the most common value in a real
/// workspace by a wide margin, so a priority sort would open on the noise.
enum Priority: Int, Sendable, Hashable, Codable, CaseIterable {
    case none = 0
    case urgent = 1
    case high = 2
    case medium = 3
    case low = 4

    /// Urgent → High → Medium → Low → None. Lower sorts first.
    var sortRank: Int { self == .none ? 5 : rawValue }

    /// The fallback when the API sends no `priorityLabel`.
    var fallbackLabel: String {
        switch self {
        case .none: "No priority"
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var symbolName: String {
        switch self {
        case .none: "minus"
        case .urgent: "exclamationmark.square.fill"
        case .high: "chart.bar.fill"
        case .medium: "chart.bar"
        case .low: "chart.bar.doc.horizontal"
        }
    }
}

// MARK: - Workflow state

/// One of a team's workflow states. Statuses are configured per team, so two
/// teams' "To Do" are different records with different ids — and Lineado groups
/// them separately rather than folding by name (PLAN §5.2).
struct WorkflowState: Sendable, Hashable, Codable, Identifiable {
    let id: String
    let name: String
    let type: StateType
    /// Hex. Drawn as the status pill's tint.
    let color: String?
    /// Linear's ordering *within the team*. Meaningless across teams.
    let position: Double
    /// Nil on a state decoded from an issue, set on one from the states cache.
    var teamID: String?
}

/// Linear's seven workflow state types.
///
/// **Seven, not six.** `duplicate` is a real type, distinct from `canceled` —
/// verified 2026-10-20 against the live workspace, where Core UX has a
/// "Duplicate" state typed `duplicate`. All three terminal types have to be
/// excluded from the assigned-issues query or duplicates sit on the list
/// forever.
///
/// Decoded leniently via `unknown`: Linear can add a type, and an enum that
/// failed to decode one would take the whole poll down with it. (Inbox & Chill
/// learned this with `NotificationCategory`.)
enum StateType: Sendable, Hashable, Codable, CaseIterable {
    case triage
    case backlog
    case unstarted
    case started
    case completed
    case canceled
    case duplicate
    case unknown

    static var allCases: [StateType] {
        [.triage, .backlog, .unstarted, .started, .completed, .canceled, .duplicate]
    }

    /// The three types the assigned-issues query filters out.
    static let terminal: [StateType] = [.completed, .canceled, .duplicate]

    /// How status **group buckets** are ordered in the list: closest to done
    /// first (Brandon, 2026-10-20).
    ///
    /// Deliberately not `lifecycleRank` reversed. A plain reversal would put
    /// Triage *below* Backlog, and Backlog has to be the floor — it is the pile
    /// you are explicitly not working on, so nothing should sit under it.
    /// Triage sits just above it: unsorted, but still live.
    var groupRank: Int {
        switch self {
        case .started: 0
        case .unstarted: 1
        case .triage: 2
        case .backlog: 3
        case .completed: 4
        case .canceled: 5
        case .duplicate: 6
        case .unknown: 7
        }
    }

    /// Linear's own lifecycle order. Used for the **status picker**, which
    /// should read the way Linear reads, not the way the list is sorted.
    var lifecycleRank: Int {
        switch self {
        case .triage: 0
        case .backlog: 1
        case .unstarted: 2
        case .started: 3
        case .completed: 4
        case .canceled: 5
        case .duplicate: 6
        case .unknown: 7
        }
    }

    /// Hidden by the Backlog toggle. Blocked is a `backlog`-type state on Core
    /// UX, so it hides with Backlog — intended, not an oversight (PLAN §5.3).
    var isBacklog: Bool { self == .backlog }

    var wireValue: String {
        switch self {
        case .triage: "triage"
        case .backlog: "backlog"
        case .unstarted: "unstarted"
        case .started: "started"
        case .completed: "completed"
        case .canceled: "canceled"
        case .duplicate: "duplicate"
        case .unknown: "unknown"
        }
    }

    init(wireValue: String) {
        self = StateType.allCases.first { $0.wireValue == wireValue } ?? .unknown
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(wireValue: raw)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - CalendarDate

/// A date with no time and no zone, matching Linear's `TimelessDate` scalar.
///
/// Modelled as its own type rather than a `Date` so that "due today" cannot
/// drift across a timezone change, and so round-tripping through the API is
/// lossless: the wire format is exactly `yyyy-MM-dd`.
struct CalendarDate: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `2026-11-05`, and tolerates a full ISO8601 timestamp by taking
    /// its date part — Linear returns `dueDate` as a bare date today, but
    /// `targetDate` has been seen both ways.
    init?(wireValue: String) {
        let datePart = wireValue.prefix(10)
        let parts = datePart.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var wireValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { wireValue }

    static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Calendar bridging

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func today(calendar: Calendar = .current, now: Date = Date()) -> CalendarDate {
        CalendarDate(now, calendar: calendar)
    }

    func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Whole days from `other` to `self`; negative when `self` is earlier.
    func days(since other: CalendarDate, calendar: Calendar = .current) -> Int? {
        guard let a = other.date(calendar: calendar), let b = date(calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    func adding(days: Int, calendar: Calendar = .current) -> CalendarDate? {
        guard let base = date(calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return CalendarDate(moved, calendar: calendar)
    }

    // Codable as the wire string, so the cache file stays readable.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = CalendarDate(wireValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        self = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
