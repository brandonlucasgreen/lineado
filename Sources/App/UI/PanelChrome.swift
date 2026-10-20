import AppKit
import SwiftUI

/// The team filter bar — the direct analogue of Inbox & Chill's source chips.
///
/// "All" plus one chip per team that currently has a visible issue, with counts.
/// `←`/`→` cycles, `⌘1`…`⌘9` jumps, and the choice persists.
struct TeamChips: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        let chips = app.teamChips

        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                chip(title: "All", count: chips.reduce(0) { $0 + $1.count },
                     isSelected: app.preferences.teamID == nil) {
                    app.preferences.teamID = nil
                }
                ForEach(Array(chips.enumerated()), id: \.element.team.id) { index, entry in
                    chip(title: entry.team.key, count: entry.count,
                         isSelected: app.preferences.teamID == entry.team.id,
                         shortcut: index < 9 ? "⌘\(index + 1)" : nil) {
                        app.preferences.teamID = entry.team.id
                    }
                    .help(entry.team.name)
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.never)
        .frame(height: 24)
    }

    private func chip(
        title: String, count: Int, isSelected: Bool,
        shortcut: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(.caption, design: .monospaced))
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isSelected
                               ? Color.accentColor.opacity(0.25)
                               : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
    }
}

/// The footer: what is hidden and why, when it synced, and the keys.
///
/// The hidden-count line is load-bearing. The list is filtered three ways and
/// locally hidden a fourth, and without an account of what is off screen the
/// panel would quietly understate the work.
struct FooterView: View {
    @Environment(AppState.self) private var app
    @State private var showsAllShortcuts = false

    var body: some View {
        HStack(spacing: 8) {
            if let error = app.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text("\(app.orderedIssues.count) task\(app.orderedIssues.count == 1 ? "" : "s")")
                if !app.hiddenCounts.isEmpty {
                    Text(hiddenSummary)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if app.isSyncing {
                ProgressView().controlSize(.mini)
            } else if let synced = app.lastSyncedAt {
                Text(synced.shortRelative).foregroundStyle(.tertiary)
            }

            Menu {
                FooterMenuItems(showsAllShortcuts: $showsAllShortcuts)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $showsAllShortcuts, arrowEdge: .top) {
                AllShortcutsView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Each reason named separately, because "12 hidden" invites the wrong
    /// guess about which filter is responsible.
    private var hiddenSummary: String {
        let counts = app.hiddenCounts
        var parts: [String] = []
        if counts.backlog > 0 { parts.append("\(counts.backlog) backlog") }
        if counts.otherTeams > 0 { parts.append("\(counts.otherTeams) other teams") }
        if counts.snoozed > 0 { parts.append("\(counts.snoozed) hidden") }
        if counts.search > 0 { parts.append("\(counts.search) filtered") }
        return "· " + parts.joined(separator: ", ")
    }
}

struct FooterMenuItems: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Binding var showsAllShortcuts: Bool

    var body: some View {
        @Bindable var app = app

        Toggle("Show Backlog", isOn: $app.preferences.showsBacklog)
            .help("B — also shows Blocked, which Linear types as backlog")

        if let undo = app.undoLabel {
            Button("Undo \(undo)") { app.undoLastChange() }
        }

        Divider()
        Button("All Keyboard Shortcuts…") { showsAllShortcuts = true }
        Button("Settings…") { SettingsWindow.open(using: openSettings) }
        Button("Quit Lineado") { NSApp.terminate(nil) }
    }
}

/// Grouping and sorting, as a menu — the same choices the `G` and `O` keys
/// cycle, spelled out so they are discoverable without folklore.
struct GroupSortMenuItems: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        Picker("Group by", selection: $app.preferences.groupBy) {
            ForEach(GroupBy.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        Picker("Sort by", selection: $app.preferences.sortBy) {
            ForEach(SortBy.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        Toggle("Ascending", isOn: $app.preferences.sortAscending)
    }
}

// MARK: - Empty and unconfigured states

/// Teaches without becoming onboarding clutter.
struct EmptyStateView: View {
    let hasAnyIssues: Bool
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 10) {
            Spacer()
            Image(systemName: hasAnyIssues ? "line.3.horizontal.decrease.circle" : "checkmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)

            Text(hasAnyIssues ? "Nothing matches" : "Nothing assigned to you")
                .font(.headline)

            // When the list is empty *because of a filter*, say which one and
            // offer the way out — an empty list that is really a hidden list is
            // the most confusing thing this panel can show.
            if hasAnyIssues {
                Text(reasonText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    if !app.searchText.isEmpty {
                        Button("Clear filter") { app.searchText = "" }
                    }
                    if app.preferences.teamID != nil {
                        Button("All teams") { app.preferences.teamID = nil }
                    }
                    if !app.preferences.showsBacklog, app.hiddenCounts.backlog > 0 {
                        Button("Show backlog") { app.preferences.showsBacklog = true }
                    }
                }
                .controlSize(.small)
            } else {
                Text("Inbox zero, in the Linear sense.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var reasonText: String {
        let counts = app.hiddenCounts
        var parts: [String] = []
        if counts.search > 0 { parts.append("\(counts.search) by the filter") }
        if counts.otherTeams > 0 { parts.append("\(counts.otherTeams) on other teams") }
        if counts.backlog > 0 { parts.append("\(counts.backlog) in backlog") }
        if counts.snoozed > 0 { parts.append("\(counts.snoozed) hidden until later") }
        guard !parts.isEmpty else { return "Every assigned task is filtered out." }
        return parts.joined(separator: ", ") + "."
    }
}

struct UnconfiguredView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "key")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Add your Linear API key").font(.headline)
            Text("Linear → Settings → Security & access → Personal API keys")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings…") { SettingsWindow.open(using: openSettings) }
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Settings window

/// Opens Settings and actually puts it in front.
///
/// `openSettings()` alone is not enough in an `LSUIElement` app. An accessory
/// app is never "active", so the window it opens is ordered into a layer behind
/// whatever the user was looking at — it opens, correctly, somewhere they
/// cannot see. The app has to activate itself and order the window front, and
/// that has to happen *after* the current runloop turn, because the window does
/// not exist until `openSettings()` returns.
@MainActor
enum SettingsWindow {
    static func open(using openSettings: OpenSettingsAction) {
        openSettings()
        bringToFront()
    }

    /// For the status item's right-click menu, which has no SwiftUI
    /// environment to read `openSettings` from.
    static func openFromMenuBar() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringToFront()
    }

    private static func bringToFront() {

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = settingsWindow else { return }
            window.makeKeyAndOrderFront(nil)
            // `orderFrontRegardless` is what gets it past the accessory app's
            // window level; `makeKeyAndOrderFront` alone can still land behind.
            window.orderFrontRegardless()
            window.center()
        }
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue.contains("Settings") == true { return true }
            return window.title == "Settings" || window.title.hasSuffix("Settings")
        }
    }
}
