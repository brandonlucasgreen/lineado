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
            .font(.system(size: ChromeType.keyCap, weight: .medium, design: .rounded))
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
                        ForEach(hint.display.split(separator: " "), id: \.self) { key in
                            KeyCap(key: String(key))
                        }
                        Text(hint.short)
                            .font(.system(size: ChromeType.hint))
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

    /// Derived from `KeyMap.bindings`, never hand-written.
    ///
    /// The previous version listed its own keys and drifted: the audit moved
    /// due date to `D` and this bar went on advertising `T`, so pressing the
    /// advertised key typed into the filter instead.
    private var hints: [KeyBinding] {
        // In the chip rows the issue verbs are inert, so advertising them
        // would be worse than showing nothing.
        if app.filterFocus != .list {
            return [
                KeyBinding("← →", app.focusedFilterName, "", .move),
                KeyBinding("↑ ↓", "move between rows", "", .move),
                KeyBinding("esc", "back to list", "", .move),
            ]
        }

        let hasSelection = app.selectedIssue != nil
        var result = KeyMap.bindings.filter { binding in
            guard binding.category == .act || binding.category == .view else { return false }
            if binding.needsSelection && !hasSelection { return false }
            // Undo advertises itself only when there is something to undo.
            if binding.action == .undo { return app.undoLabel != nil }
            return true
        }

        result.append(KeyBinding("← →", app.focusedFilterName, "", .move))
        if app.showsWorkspaceDimension {
            result.append(KeyBinding("↑", "team filter", "", .move))
        }
        return result
    }
}

/// The full list, for the "..." menu — the same table, grouped.
struct AllShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(KeyBinding.Category.allCases, id: \.self) { category in
                    let bindings = KeyMap.bindings.filter { $0.category == category }
                    if !bindings.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(bindings) { binding in
                                HStack(spacing: 4) {
                                    ForEach(binding.display.split(separator: " "), id: \.self) { key in
                                        KeyCap(key: String(key))
                                    }
                                    Text(binding.long.isEmpty ? binding.short : binding.long)
                                        .font(.system(size: 11))
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 320, height: 440)
    }
}
