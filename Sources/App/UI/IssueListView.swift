import SwiftUI

/// The list, shared by the menu bar panel and the `⌘0` window.
///
/// One view for both surfaces, so a verb cannot work in one and not the other —
/// which is the drift that makes a two-surface app feel like two apps.
struct IssueListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var app = app

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(app.sections) { section in
                        Section {
                            ForEach(section.issues) { issue in
                                row(for: issue)
                                    .id(issue.id)
                            }
                        } header: {
                            if !section.title.isEmpty {
                                SectionHeader(section: section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: app.selectionID) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func row(for issue: Issue) -> some View {
        IssueRowView(
            issue: issue,
            isSelected: app.selectionID == issue.id,
            isExpanded: app.expandedID == issue.id,
            detail: app.details[issue.id],
            errorMessage: app.rowError(for: issue.id),
            // Chrome the group header already carries is dropped from the row
            // rather than squeezed into it. On a 460pt panel the difference
            // between four trailing elements and two is the difference between
            // a readable title and an ellipsis.
            showsTeam: app.preferences.teamID == nil && app.preferences.groupBy != .team,
            showsStatus: app.preferences.groupBy != .status,
            showsPriority: app.preferences.groupBy != .priority)
        .onTapGesture {
            app.selectionID = issue.id
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { open(issue) })
        .contextMenu { IssueContextMenu(issue: issue) }
    }

    private func open(_ issue: Issue) {
        guard let url = URL(string: issue.url) else { return }
        openURL(url)
    }
}

/// A pinned group header. The subtitle carries a `Project ›` prefix for
/// milestones, or a team key where two teams use the same status name.
struct SectionHeader: View {
    let section: IssueSection

    var body: some View {
        HStack(spacing: 6) {
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .foregroundStyle(.tertiary)
                Text("›")
                    .foregroundStyle(.quaternary)
            }
            Text(section.title)
                .foregroundStyle(.secondary)
            Text("\(section.issues.count)")
                .foregroundStyle(.tertiary)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Opaque, not material: these headers are pinned, so rows scroll
        // underneath them and anything translucent shows the text sliding
        // through.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Mirrors the Task menu, so right-click offers exactly what the keyboard does.
struct IssueContextMenu: View {
    let issue: Issue
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open in Linear") {
            if let url = URL(string: issue.url) { openURL(url) }
        }
        Button("Complete") { app.complete(issue) }

        Divider()

        Menu("Status") {
            ForEach(app.availableStates(for: issue)) { state in
                Button(state.name) { app.setState(issue, to: state) }
            }
        }
        Menu("Priority") {
            ForEach(Priority.allCases, id: \.self) { priority in
                Button(priority.fallbackLabel) { app.setPriority(issue, to: priority) }
            }
        }
        Menu("Due Date") {
            Button("Today") { app.setDueDate(issue, to: .today()) }
            Button("Tomorrow") { app.setDueDate(issue, to: CalendarDate.today().adding(days: 1)) }
            Button("Next week") { app.setDueDate(issue, to: CalendarDate.today().adding(days: 7)) }
            Divider()
            Button("Clear") { app.setDueDate(issue, to: nil) }
        }

        Divider()

        Button("Copy Link") { IssuePasteboard.copy(issue) }
        Button("Copy Branch Name") { IssuePasteboard.copyBranchName(issue) }
    }
}
