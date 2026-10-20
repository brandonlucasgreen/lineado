import Foundation

/// One Linear workspace, and the credential that reaches it.
///
/// A workspace is identified by a locally-generated UUID rather than by
/// Linear's organization id, because the row has to exist *before* the key is
/// validated — you add a workspace, paste a key, and only then does Linear
/// tell us what the organization is called. Using a remote id as the primary
/// key would mean having no key until the first successful poll.
///
/// The API key never lives here. It is in the Keychain under
/// `workspace.<id>.apiKey`, and only the account name is derived from this.
struct Workspace: Identifiable, Sendable, Hashable, Codable {
    let id: String
    /// Linear's own name for the organization, filled in on the first
    /// successful poll. Until then this is whatever the user typed, or a
    /// placeholder.
    var name: String
    /// Linear's `urlKey` — the subdomain, used for a short chip label.
    var urlKey: String?
    /// Lets a workspace be silenced without deleting its key.
    var isEnabled: Bool = true

    var keychainAccount: String { "workspace.\(id).apiKey" }

    /// Three or four characters for a filter chip.
    var shortLabel: String {
        if let urlKey, !urlKey.isEmpty { return urlKey.uppercased() }
        let letters = name.split(separator: " ").compactMap(\.first)
        if letters.count >= 2 { return String(letters.prefix(3)).uppercased() }
        return String(name.prefix(4)).uppercased()
    }

    init(id: String = UUID().uuidString, name: String, urlKey: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.urlKey = urlKey
        self.isEnabled = isEnabled
    }
}

/// The configured workspaces, and their credentials.
///
/// Stored as JSON beside the issue cache. The list is small, it is not secret,
/// and keeping it out of `UserDefaults` means the whole of the app's own state
/// lives in one directory you can delete to start over.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []

    private var file: URL { Storage.directory.appendingPathComponent("workspaces.json") }

    init() {
        load()
        migrateLegacyKeyIfNeeded()
    }

    var enabled: [Workspace] { workspaces.filter(\.isEnabled) }

    var hasAnyKey: Bool {
        enabled.contains { Keychain.get($0.keychainAccount)?.isEmpty == false }
    }

    /// True while only one workspace is configured, which is the common case.
    /// The UI uses this to hide the whole workspace dimension rather than
    /// show a filter row with one chip in it.
    var isSingleWorkspace: Bool { workspaces.count <= 1 }

    func workspace(id: String) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    // MARK: Mutating

    @discardableResult
    func add(name: String, apiKey: String) -> Workspace {
        let workspace = Workspace(name: name.isEmpty ? "New workspace" : name)
        Keychain.set(apiKey, for: workspace.keychainAccount)
        workspaces.append(workspace)
        save()
        return workspace
    }

    func setKey(_ key: String, for id: String) {
        guard let workspace = workspace(id: id) else { return }
        Keychain.set(key, for: workspace.keychainAccount)
    }

    func hasKey(for id: String) -> Bool {
        guard let workspace = workspace(id: id) else { return false }
        return Keychain.get(workspace.keychainAccount)?.isEmpty == false
    }

    func remove(id: String) {
        guard let workspace = workspace(id: id) else { return }
        // The credential goes with it. Leaving an orphaned Keychain item for a
        // workspace with no row is a secret nobody can see or delete from here.
        Keychain.set(nil, for: workspace.keychainAccount)
        workspaces.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].isEnabled = enabled
        save()
    }

    /// Called after a poll, with whatever Linear said the organization is.
    func updateIdentity(id: String, name: String, urlKey: String?) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard !name.isEmpty else { return }
        guard workspaces[index].name != name || workspaces[index].urlKey != urlKey else { return }
        workspaces[index].name = name
        workspaces[index].urlKey = urlKey
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            workspaces = try JSONDecoder().decode([Workspace].self, from: data)
        } catch {
            log.error("Discarding unreadable workspace list: \(String(describing: error))")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(workspaces).write(to: file, options: .atomic)
        } catch {
            log.error("Couldn't write workspace list: \(String(describing: error))")
        }
    }

    /// Moves a pre-multi-workspace key into the new shape.
    ///
    /// Silent and one-way: someone who had a working key must not open the app
    /// to an empty list and a prompt to paste it again.
    private func migrateLegacyKeyIfNeeded() {
        guard workspaces.isEmpty,
              let legacy = Keychain.get(Keychain.apiKeyAccount), !legacy.isEmpty
        else { return }

        let workspace = Workspace(name: "Linear")
        Keychain.set(legacy, for: workspace.keychainAccount)
        workspaces = [workspace]
        save()
        // Only drop the old item once the new one is readable, so an
        // interrupted migration cannot lose the key.
        if Keychain.get(workspace.keychainAccount) == legacy {
            Keychain.set(nil, for: Keychain.apiKeyAccount)
            log.info("Migrated the single API key into a workspace")
        }
    }
}
