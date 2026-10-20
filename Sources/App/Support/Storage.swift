import Foundation
import OSLog

let log = Logger(subsystem: "lol.bgreen.lineado", category: "app")

/// Where the two JSON files live.
///
/// This is the whole persistence story (PLAN §4.2). There is no database: every
/// issue has a canonical record in Linear, so the only things worth keeping
/// across launches are a snapshot to render before the first poll returns, and
/// the one piece of state Linear does not have.
enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Lineado", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var cacheFile: URL { directory.appendingPathComponent("issues.json") }
    static var localStateFile: URL { directory.appendingPathComponent("local-state.json") }
}

// MARK: - Issue cache

/// The last successful snapshot.
///
/// Its only job is that opening the panel before the first poll completes shows
/// the previous list instead of a spinner. It is never merged with, reconciled
/// against or trusted over a live response — a poll replaces it wholesale.
struct IssueCache: Codable, Sendable {
    var issues: [Issue]
    var savedAt: Date

    static func load() -> IssueCache? {
        guard let data = try? Data(contentsOf: Storage.cacheFile) else { return nil }
        do {
            return try JSONDecoder.linear.decode(IssueCache.self, from: data)
        } catch {
            // A cache that cannot be read is not an error worth showing anyone:
            // the next poll replaces it. But it must be *logged*, because a
            // decode failure here means the model changed shape and silently
            // cost every user their cold start.
            log.error("Discarding unreadable issue cache: \(String(describing: error))")
            try? FileManager.default.removeItem(at: Storage.cacheFile)
            return nil
        }
    }

    static func save(_ issues: [Issue]) {
        let snapshot = IssueCache(issues: issues, savedAt: Date())
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: Storage.cacheFile, options: .atomic)
        } catch {
            log.error("Couldn't write issue cache: \(String(describing: error))")
        }
    }
}

// MARK: - Local state

/// The only state Lineado authors rather than mirrors.
///
/// `H` hides an issue locally until a date without touching Linear — the escape
/// hatch for an active issue you do not want to look at this week and cannot
/// honestly move to Backlog, because your team reads status (PLAN §4.3).
///
/// Deliberately the *only* local state. A "Today" flag and manual ordering were
/// both considered and cut: each introduces a second ordering authority that
/// fights the sort/group model and has to be reconciled on every poll.
struct LocalState: Codable, Sendable, Equatable {
    /// Issue id → the moment it comes back.
    var hiddenUntil: [String: Date] = [:]

    static func load() -> LocalState {
        guard let data = try? Data(contentsOf: Storage.localStateFile) else { return LocalState() }
        do {
            return try JSONDecoder.linear.decode(LocalState.self, from: data)
        } catch {
            log.error("Discarding unreadable local state: \(String(describing: error))")
            return LocalState()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Storage.localStateFile, options: .atomic)
        } catch {
            log.error("Couldn't write local state: \(String(describing: error))")
        }
    }

    /// Drops entries whose date has passed, and any issue no longer on the list.
    ///
    /// Without the second half, hiding an issue that is later completed in
    /// Linear leaves its id in this file forever.
    mutating func prune(livingIssueIDs: Set<String>, now: Date = Date()) {
        hiddenUntil = hiddenUntil.filter { id, until in
            until > now && livingIssueIDs.contains(id)
        }
    }
}
