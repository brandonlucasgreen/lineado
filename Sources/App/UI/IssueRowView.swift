import SwiftUI

/// One issue, one line.
///
/// One line at rest; the selected row grows to show whatever detail has been
/// fetched. One line is enough to tell issues apart and rarely enough to act on
/// one, so the row you are actually looking at is the one that shows its text —
/// the same rule as Inbox & Chill's queue.
struct IssueRowView: View {
    let issue: Issue
    let isSelected: Bool
    let isExpanded: Bool
    let detail: IssueDetail?
    let errorMessage: String?
    let showsTeam: Bool

    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headline

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if isExpanded {
                IssueDetailView(issue: issue, detail: detail)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Dragging a row out gives a URL and plain text, so dropping it on
        // Things, Notes, Slack or a browser does the obvious thing.
        .draggable(IssuePasteboard.plainText(for: issue)) {
            Label(issue.identifier, systemImage: "square.and.arrow.up")
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.priority.symbolName)
                .font(.caption)
                .foregroundStyle(issue.priority == .none ? Color.secondary : issue.priority.tint)
                .frame(width: 12)
                .help(issue.priorityLabel ?? issue.priority.fallbackLabel)

            Text(issue.identifier)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .layoutPriority(1)

            Text(issue.title)
                .lineLimit(isSelected ? 2 : 1)
                .layoutPriority(2)

            Spacer(minLength: 8)

            trailingCluster
        }
    }

    @ViewBuilder
    private var trailingCluster: some View {
        HStack(spacing: 6) {
            if issue.isPending {
                ProgressView()
                    .controlSize(.mini)
                    .help("Saving to Linear…")
            }

            if let due = issue.dueDate {
                let rendered = DueDateStyle.render(due)
                Text(rendered.text)
                    .font(.caption)
                    .foregroundStyle(rendered.tint)
                    .fontWeight(rendered.isAlarming ? .semibold : .regular)
            }

            StatusPill(state: issue.state)

            if showsTeam {
                Text(issue.team.key)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .layoutPriority(1)
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// Reads the way you would say it out loud, not the way the row is laid out.
    private var accessibilityLabel: String {
        var parts = [issue.identifier, issue.title]
        parts.append(issue.priorityLabel ?? issue.priority.fallbackLabel)
        if let due = issue.dueDate {
            parts.append("due " + DueDateStyle.render(due).text)
        }
        parts.append(issue.state.name)
        parts.append(issue.team.name)
        return parts.joined(separator: ", ")
    }
}

/// The status pill, tinted with the state's own Linear colour.
struct StatusPill: View {
    let state: WorkflowState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(linearHex: state.color) ?? .secondary)
                .frame(width: 7, height: 7)
            Text(state.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.primary.opacity(0.06)))
    }
}
