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

    var body: some View {
        @Bindable var app = app

        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Toggle Lineado", name: .togglePanel)
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
