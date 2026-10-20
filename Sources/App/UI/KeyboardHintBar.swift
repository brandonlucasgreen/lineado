import SwiftUI

/// One key, drawn as a key.
///
/// A monospaced cap with a border reads as "press this" at a glance, where the
/// same character in body text reads as punctuation. Inbox & Chill's hint bar
/// is the reference.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .frame(minWidth: 16)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Color.primary.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// A key and what it does.
struct KeyHint: Identifiable {
    let id = UUID()
    let keys: [String]
    let label: String

    // Two explicit inits rather than `(_ keys: String..., _ label: String)`:
    // Swift requires a label on any parameter following a variadic one, which
    // would have put `label:` at every call site for no benefit.
    init(_ key: String, _ label: String) {
        self.keys = [key]
        self.label = label
    }

    init(_ firstKey: String, _ secondKey: String, _ label: String) {
        self.keys = [firstKey, secondKey]
        self.label = label
    }
}

/// The strip of shortcuts along the bottom of the panel.
///
/// This app is keyboard-first and most of its verbs are single letters, which
/// is fast once known and invisible until then. The window has a real menu bar
/// to make them discoverable; the *panel* has no menu bar at all, so without
/// this strip every shortcut in it is folklore.
///
/// The hints are **contextual**: they describe what the keys do right now. A
/// strip that always says the same thing becomes wallpaper within a day, and a
/// strip advertising `S` when nothing is selected is worse than none.
struct KeyboardHintBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(hints) { hint in
                    HStack(spacing: 3) {
                        ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in
                            KeyCap(key: key)
                        }
                        Text(hint.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.never)
        .background(Color.primary.opacity(0.03))
    }

    private var hints: [KeyHint] {
        guard app.selectedIssue != nil else {
            // Nothing selected: the only useful keys are the ones that change
            // what the list shows.
            return [
                KeyHint("↑", "↓", "move"),
                KeyHint("G", "group"),
                KeyHint("O", "sort"),
                KeyHint("B", "backlog"),
                KeyHint("⌘R", "refresh"),
            ]
        }

        var result: [KeyHint] = [
            KeyHint("⏎", "open"),
            KeyHint("E", "done"),
            KeyHint("S", "status"),
            KeyHint("P", "priority"),
            KeyHint("T", "due"),
            KeyHint("C", "comment"),
            KeyHint("space", "detail"),
            KeyHint("H", "hide"),
        ]
        // Undo only appears when there is something to undo, and says what.
        if let undo = app.undoLabel {
            result.insert(KeyHint("⌘Z", "undo \(undo.lowercased())"), at: 0)
        }
        result.append(contentsOf: [
            KeyHint("G", "group"),
            KeyHint("O", "sort"),
            KeyHint("B", "backlog"),
            KeyHint("⌘0", "window"),
        ])
        return result
    }
}

/// The full list, for the "..." menu — everything the strip cannot fit.
struct AllShortcutsView: View {
    private let groups: [(String, [KeyHint])] = [
        ("Move", [
            KeyHint("↑", "↓", "Move selection"),
            KeyHint("⌥↑", "⌥↓", "Previous / next group"),
            KeyHint("←", "→", "Cycle team"),
            KeyHint("⌘1", "…", "Jump to team"),
        ]),
        ("Act", [
            KeyHint("⏎", "Open in Linear"),
            KeyHint("E", "Complete"),
            KeyHint("S", "Status"),
            KeyHint("P", "Priority"),
            KeyHint("T", "Due date"),
            KeyHint("C", "Comment"),
            KeyHint("H", "Hide until later"),
            KeyHint("⌘Z", "Undo"),
        ]),
        ("View", [
            KeyHint("space", "Expand detail"),
            KeyHint("G", "Cycle grouping"),
            KeyHint("O", "Cycle sorting"),
            KeyHint("B", "Show / hide backlog"),
            KeyHint("⌘F", "Filter"),
            KeyHint("⌘R", "Refresh"),
            KeyHint("⌘0", "Open in a window"),
        ]),
        ("Copy", [
            KeyHint("⌘C", "Copy link"),
            KeyHint("⇧⌘C", "Copy branch name"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.0)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        ForEach(group.1) { hint in
                            HStack(spacing: 4) {
                                ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in
                                    KeyCap(key: key)
                                }
                                Text(hint.label)
                                    .font(.system(size: 11))
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 320, height: 420)
    }
}
