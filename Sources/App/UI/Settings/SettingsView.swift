import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings()
                .tabItem { Label("Linear", systemImage: "square.stack.3d.up") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 460)
    }
}

struct AccountSettings: View {
    @Environment(AppState.self) private var app
    @State private var key: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                // A SecureField, and the value is never echoed back from the
                // Keychain into the UI — the field starts empty on every visit
                // and an empty save is a no-op, so "I didn't retype it" cannot
                // silently clear a working key.
                SecureField("Personal API key", text: $key)
                    .onSubmit(save)
                HStack {
                    Button("Save", action: save)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if Keychain.hasAPIKey() {
                        Button("Remove", role: .destructive) {
                            Keychain.set(nil, for: Keychain.apiKeyAccount)
                            key = ""
                            saved = false
                        }
                    }
                    Spacer()
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if Keychain.hasAPIKey() {
                        Label("A key is stored", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Linear")
            } footer: {
                Text("Linear → Settings → Security & access → Personal API keys. Stored in your login keychain, never in a file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !app.viewerName.isEmpty {
                LabeledContent("Signed in as", value: app.viewerName)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, for: Keychain.apiKeyAccount)
        key = ""
        saved = true
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
