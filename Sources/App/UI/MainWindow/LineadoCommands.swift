import SwiftUI

/// The real menu bar.
///
/// This is the single largest Mac-arsed difference between a good menu bar app
/// and a web app in a popover: every verb the keyboard offers is also a menu
/// item with its shortcut printed next to it, so the keyboard map is
/// discoverable rather than folklore (PLAN §6.3).
///
/// The Task submenus are populated from the *selected issue's team*, so the
/// status list is that team's real workflow states and never a workspace-wide
/// list the mutation would reject.
struct LineadoCommands: Commands {
    let app: AppState
    let updates: UpdateController

    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Open in Linear") { openSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(app.selectedIssue == nil)

            Button("Copy Link") {
                if let issue = app.selectedIssue { IssuePasteboard.copy(issue) }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(app.selectedIssue == nil)

            Button("Copy Branch Name") {
                if let issue = app.selectedIssue { IssuePasteboard.copyBranchName(issue) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(app.selectedIssue == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(app.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                app.undoLastChange()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(app.undoLabel == nil)
        }

        CommandMenu("Task") {
            Button("Complete") {
                if let issue = app.selectedIssue { app.complete(issue) }
            }
            .keyboardShortcut("e", modifiers: [])
            .disabled(app.selectedIssue == nil)

            Divider()

            Menu("Status") {
                if let issue = app.selectedIssue {
                    ForEach(app.availableStates(for: issue)) { state in
                        Button(state.name) { app.setState(issue, to: state) }
                    }
                }
            }
            .disabled(app.selectedIssue == nil)

            Menu("Priority") {
                if let issue = app.selectedIssue {
                    ForEach(Priority.allCases.sorted { $0.sortRank < $1.sortRank }, id: \.self) { priority in
                        Button(priority.fallbackLabel) { app.setPriority(issue, to: priority) }
                    }
                }
            }
            .disabled(app.selectedIssue == nil)

            Menu("Due Date") {
                if let issue = app.selectedIssue {
                    Button("Today") { app.setDueDate(issue, to: .today()) }
                    Button("Tomorrow") { app.setDueDate(issue, to: CalendarDate.today().adding(days: 1)) }
                    Button("Next Week") { app.setDueDate(issue, to: CalendarDate.today().adding(days: 7)) }
                    Divider()
                    Button("Clear") { app.setDueDate(issue, to: nil) }
                        .disabled(issue.dueDate == nil)
                }
            }
            .disabled(app.selectedIssue == nil)

            Divider()

            Menu("Hide Until") {
                if let issue = app.selectedIssue {
                    Button("Tomorrow") { app.hide(issue, until: Date().addingTimeInterval(86400)) }
                    Button("Next Week") { app.hide(issue, until: Date().addingTimeInterval(7 * 86400)) }
                    Button("In a Month") { app.hide(issue, until: Date().addingTimeInterval(30 * 86400)) }
                }
            }
            .disabled(app.selectedIssue == nil)
        }

        CommandMenu("View") {
            Picker("Group By", selection: Binding(
                get: { app.preferences.groupBy },
                set: { app.preferences.groupBy = $0 })) {
                    ForEach(GroupBy.allCases) { Text($0.label).tag($0) }
                }

            Picker("Sort By", selection: Binding(
                get: { app.preferences.sortBy },
                set: { app.preferences.sortBy = $0 })) {
                    ForEach(SortBy.allCases) { Text($0.label).tag($0) }
                }

            Toggle("Ascending", isOn: Binding(
                get: { app.preferences.sortAscending },
                set: { app.preferences.sortAscending = $0 }))

            Divider()

            Toggle("Show Backlog", isOn: Binding(
                get: { app.preferences.showsBacklog },
                set: { app.preferences.showsBacklog = $0 }))
                .keyboardShortcut("b", modifiers: [])

            Divider()

            Button("Refresh") { Task { await app.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.isSyncing)
        }
    }

    private func openSelected() {
        guard let issue = app.selectedIssue, let url = URL(string: issue.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The `⌘0` window: the same list, with the menu bar above it.
struct MainWindowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter…", text: $app.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                VStack(alignment: .leading, spacing: 4) {
                    WorkspaceChips()
                    TeamChips()
                }
                Spacer()
            }
            .padding(10)

            Divider()

            if !app.isConfigured {
                UnconfiguredView()
            } else if app.orderedIssues.isEmpty {
                EmptyStateView(hasAnyIssues: !app.issues.isEmpty)
            } else {
                IssueListView()
            }

            Divider()
            FooterView()
        }
        .frame(minWidth: 560, minHeight: 400)
        // Refresh on open only; the poll loop belongs to the app (see
        // `LineadoApp`), so opening and closing this window never interrupts it.
        .task { await app.refresh() }
    }
}
