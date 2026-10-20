import SwiftUI

/// One issue, one line.
///
/// One line at rest; the selected row grows to show whatever detail has been
/// fetched. One line is enough to tell issues apart and rarely enough to act on
/// one, so the row you are actually looking at is the one that shows its text —
/// the same rule as Inbox & Chill's queue.
///
/// **The layout rule that this view exists to get right:** exactly one element
/// is allowed to be flexible — the title. Everything else is `fixedSize()`.
/// Without that, SwiftUI resolves a crowded `HStack` by compressing the
/// *narrowest* views first, and a status pill compressed below its text width
/// wraps one letter per line: a seven-line-tall row reading "B a c k l o g".
/// Layout priority alone does not prevent it, because priority decides who
/// gives up space, not whether a view may wrap.
struct IssueRowView: View {
    let issue: Issue
    let isSelected: Bool
    let isExpanded: Bool
    let detail: IssueDetail?
    let errorMessage: String?
    let showsTeam: Bool
    /// Redundant chrome is hidden rather than shrunk: grouping by status
    /// already puts the status in the header above the row.
    let showsStatus: Bool
    let showsPriority: Bool

    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headline

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if isExpanded {
                IssueDetailView(issue: issue, detail: detail)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        HStack(spacing: 7) {
            if showsPriority {
                PriorityIcon(priority: issue.priority)
                    .help(issue.priorityLabel ?? issue.priority.fallbackLabel)
            }

            Text(issue.identifier)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()

            Text(issue.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                // The only flexible element in the row.
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingCluster
        }
        // A uniform row height, so the list reads as a list rather than as a
        // stack of differently sized cards.
        .frame(minHeight: 18)
    }

    private var trailingCluster: some View {
        HStack(spacing: 6) {
            if issue.isPending {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10)
                    .help("Saving to Linear…")
            }

            if let due = issue.dueDate {
                let rendered = DueDateStyle.render(due)
                Text(rendered.text)
                    .font(.system(size: 11))
                    .foregroundStyle(rendered.tint)
                    .fontWeight(rendered.isAlarming ? .semibold : .regular)
                    .lineLimit(1)
            }

            if showsStatus {
                StatusPill(state: issue.state)
            }

            if showsTeam {
                Text(issue.team.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
        }
        // Everything here keeps its natural width. The title truncates instead.
        .fixedSize()
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
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

/// Linear's priority, drawn as Linear draws it: stacked bars that fill with
/// urgency, and a dash for "no priority".
///
/// Replaces a set of SF Symbols that read as unrelated pictures in a column —
/// `chart.bar.doc.horizontal` for Low in particular looked like a document
/// icon and implied the row was a different *kind* of thing.
struct PriorityIcon: View {
    let priority: Priority

    var body: some View {
        Group {
            switch priority {
            case .none:
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.quaternary)
            case .urgent:
                Image(systemName: "exclamationmark.square.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(priority.tint)
            default:
                bars
            }
        }
        .frame(width: 12, height: 12)
    }

    /// Three bars; the filled count rises with priority, so the glyphs differ
    /// by amount rather than by picture and a column of them is scannable.
    private var bars: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(index < filledBars ? AnyShapeStyle(priority.tint)
                                             : AnyShapeStyle(Color.quaternaryLabel))
                    .frame(width: 2.5, height: 4 + CGFloat(index) * 3)
            }
        }
    }

    private var filledBars: Int {
        switch priority {
        case .high: 3
        case .medium: 2
        case .low: 1
        default: 0
        }
    }
}

extension Color {
    static let quaternaryLabel = Color(nsColor: .quaternaryLabelColor)
}

/// The status pill, tinted with the state's own Linear colour.
///
/// `fixedSize` and `lineLimit(1)` are load-bearing, not decoration: this is the
/// view that wrapped into a vertical letter column when the row got crowded.
struct StatusPill: View {
    let state: WorkflowState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(linearHex: state.color) ?? .secondary)
                .frame(width: 6, height: 6)
            Text(state.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }
}
