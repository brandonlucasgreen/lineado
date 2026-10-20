import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings()
                .tabItem { Label("Workspaces", systemImage: "square.stack.3d.up") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 460)
    }
}

struct AccountSettings: View {
    @Environment(AppState.self) private var app
    @State private var newKey = ""
    @State private var isAdding = false

    var body: some View {
        @Bindable var app = app

        Form {
            ForEach(app.workspaces.workspaces) { workspace in
                WorkspaceRow(workspace: workspace)
            }

            Section {
                if isAdding {
                    SecureField("Paste a personal API key", text: $newKey)
                        .onSubmit(addWorkspace)
                    HStack {
                        Button("Add", action: addWorkspace)
                            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { isAdding = false; newKey = "" }
                        Spacer()
                    }
                } else {
                    Button("Add Workspace…") { isAdding = true }
                }
            } header: {
                Text(app.workspaces.workspaces.isEmpty ? "Linear" : "Another workspace")
            } footer: {
                Text("Linear → Settings → Security & access → Personal API keys. One key per workspace; each is stored in your login keychain, never in a file. Lineado names the workspace from whatever Linear reports on the first sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func addWorkspace() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Named provisionally; the first successful poll replaces this with
        // the organization's real name.
        app.workspaces.add(name: "New workspace", apiKey: key)
        newKey = ""
        isAdding = false
        Task { await app.refresh() }
    }
}

/// One configured workspace: its name, its state, and the two things you can
/// do to it.
struct WorkspaceRow: View {
    let workspace: Workspace
    @Environment(AppState.self) private var app
    @State private var replacementKey = ""
    @State private var isReplacing = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).fontWeight(.medium)
                    if let error = app.workspaceErrors[workspace.id] {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else if app.workspaces.hasKey(for: workspace.id) {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("No key").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { workspace.isEnabled },
                    set: {
                        app.workspaces.setEnabled($0, for: workspace.id)
                        Task { await app.refresh() }
                    }))
                    .labelsHidden()
                    .help("Include this workspace")
            }

            if isReplacing {
                SecureField("New API key", text: $replacementKey)
                    .onSubmit(replaceKey)
                HStack {
                    Button("Save", action: replaceKey)
                        .disabled(replacementKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isReplacing = false; replacementKey = "" }
                    Spacer()
                }
            } else {
                HStack {
                    Button("Replace Key…") { isReplacing = true }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        app.workspaces.remove(id: workspace.id)
                        Task { await app.refresh() }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func replaceKey() {
        let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        app.workspaces.setKey(key, for: workspace.id)
        replacementKey = ""
        isReplacing = false
        Task { await app.refresh() }
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        @Bindable var app = app

        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Toggle Lineado", name: .togglePanel)
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.state.isOn },
                    set: { loginItem.setEnabled($0) }))
                    .disabled(!loginItem.isEligible || loginItem.state == .unavailable)

                // Registration can succeed and still not run at login, because
                // macOS parks the item awaiting approval. Saying so — and
                // offering the one action that fixes it — beats a toggle that
                // reads "on" and does nothing.
                if loginItem.state == .requiresApproval {
                    HStack(spacing: 6) {
                        Label("Needs your approval in System Settings",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Spacer()
                        Button("Open…") { loginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }

                if let error = loginItem.errorMessage {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } footer: {
                if !loginItem.isEligible {
                    Text("Move Lineado to your Applications folder to enable this — macOS registers the app at its current location, so a copy run from elsewhere would stop working when that folder changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Refresh") {
                Picker("Check Linear every", selection: $app.preferences.pollInterval) {
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                }
            }

            Section {
                Toggle("Show backlog tasks", isOn: $app.preferences.showsBacklog)
            } footer: {
                // Said once, here, because it is the one genuinely surprising
                // consequence of the toggle.
                Text("Linear types “Blocked” as a backlog status, so this shows and hides Blocked tasks too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        // The user can flip this in System Settings at any time; without a
        // re-read the toggle would show a stale value until relaunch.
        .onAppear { loginItem.refresh() }
    }
}

struct UpdateSettings: View {
    @Environment(UpdateController.self) private var updates

    var body: some View {
        Form {
            if updates.isUpdateSigningConfigured {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.automaticallyChecks = $0 }))
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
                LabeledContent("Feed", value: updates.feedURL)
                    .font(.caption)
            } else {
                // A build that cannot install an update says so, rather than
                // offering a button that fails silently months later —
                // Inbox & Chill's trap 3.
                Section {
                    Label(updates.hasRealFeed
                          ? "This build has no update-signing key"
                          : "In-app updates aren't set up yet",
                          systemImage: "info.circle")
                    Text(updates.unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
