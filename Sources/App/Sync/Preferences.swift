import Foundation

/// Everything the app remembers between launches that is not a secret, an
/// issue, or local hide-until state (PLAN §6.6).
///
/// `UserDefaults`-backed, read once at launch and written on change. Kept as
/// one type so that "what does Lineado persist?" has a single answer.
struct Preferences: Sendable, Equatable {
    var groupBy: GroupBy = .none
    var sortBy: SortBy = .priority
    var sortAscending: Bool = true
    var showsBacklog: Bool = false
    /// Nil means the "All" chip.
    var teamID: String?
    /// Nil means every workspace.
    var workspaceID: String?
    /// Seconds between polls. Linear's personal-key budget is ~1,500 req/hour;
    /// 60s spends ~60 of it.
    var pollInterval: TimeInterval = 60

    private enum Key {
        static let groupBy = "groupBy"
        static let sortBy = "sortBy"
        static let sortAscending = "sortAscending"
        static let showsBacklog = "showsBacklog"
        static let teamID = "teamID"
        static let workspaceID = "workspaceID"
        static let pollInterval = "pollInterval"
    }

    static func load(from defaults: UserDefaults = .standard) -> Preferences {
        var prefs = Preferences()
        if let raw = defaults.string(forKey: Key.groupBy), let value = GroupBy(rawValue: raw) {
            prefs.groupBy = value
        }
        if let raw = defaults.string(forKey: Key.sortBy), let value = SortBy(rawValue: raw) {
            prefs.sortBy = value
        }
        if defaults.object(forKey: Key.sortAscending) != nil {
            prefs.sortAscending = defaults.bool(forKey: Key.sortAscending)
        }
        prefs.showsBacklog = defaults.bool(forKey: Key.showsBacklog)
        prefs.teamID = defaults.string(forKey: Key.teamID)
        prefs.workspaceID = defaults.string(forKey: Key.workspaceID)
        let interval = defaults.double(forKey: Key.pollInterval)
        if interval >= 15 { prefs.pollInterval = interval }
        return prefs
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(groupBy.rawValue, forKey: Key.groupBy)
        defaults.set(sortBy.rawValue, forKey: Key.sortBy)
        defaults.set(sortAscending, forKey: Key.sortAscending)
        defaults.set(showsBacklog, forKey: Key.showsBacklog)
        defaults.set(teamID, forKey: Key.teamID)
        defaults.set(workspaceID, forKey: Key.workspaceID)
        defaults.set(pollInterval, forKey: Key.pollInterval)
    }
}
