import SwiftUI

/// Which picker, if any, is in front of the list.
enum ActivePicker: Equatable, Identifiable {
    case status
    case priority
    case dueDate
    case hideUntil

    var id: String {
        switch self {
        case .status: "status"
        case .priority: "priority"
        case .dueDate: "due"
        case .hideUntil: "hide"
        }
    }

    var title: String {
        switch self {
        case .status: "Set status"
        case .priority: "Set priority"
        case .dueDate: "Set due date"
        case .hideUntil: "Hide until"
        }
    }
}

/// One row in a picker.
struct PickerOption<Value>: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbolName: String?
    let tint: Color?
    let value: Value

    init(id: String, title: String, subtitle: String? = nil,
         symbolName: String? = nil, tint: Color? = nil, value: Value) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.tint = tint
        self.value = value
    }
}

/// A keyboard-driven list that floats over the panel.
///
/// Deliberately not an `NSMenu`: a menu steals the key window, cannot be typed
/// into to filter, and cannot show a free-text field — all three of which the
/// due-date picker needs. Inbox & Chill's `SnoozeMenu` is the same shape for
/// the same reasons.
///
/// Type to filter, `↑`/`↓` to move, `⏎` to apply, `Esc` to cancel.
struct PickerOverlay<Value>: View {
    let title: String
    let options: [PickerOption<Value>]
    /// Shown under the field — the due picker's "today, +3d, 2026-11-05" hint.
    var hint: String?
    /// Parses typed text into a value the list cannot offer, like a date.
    var parseFreeform: ((String) -> (title: String, value: Value)?)?
    let onPick: (Value) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [PickerOption<Value>] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.title.lowercased().contains(needle)
                || ($0.subtitle?.lowercased().contains(needle) ?? false)
        }
    }

    private var freeform: (title: String, value: Value)? {
        guard let parseFreeform else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return parseFreeform(trimmed)
    }

    /// The freeform result rides at the top of the list, so `⏎` on a typed date
    /// does the obvious thing without an extra keystroke.
    private var rows: [(id: String, title: String, subtitle: String?, symbol: String?, tint: Color?, value: Value)] {
        var result: [(String, String, String?, String?, Color?, Value)] = []
        if let freeform {
            result.append(("freeform", freeform.title, "from what you typed", "return", nil, freeform.value))
        }
        result.append(contentsOf: filtered.map {
            ($0.id, $0.title, $0.subtitle, $0.symbolName, $0.tint, $0.value)
        })
        return result.map { (id: $0.0, title: $0.1, subtitle: $0.2, symbol: $0.3, tint: $0.4, value: $0.5) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            TextField("Filter…", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .focused($fieldFocused)
                .onChange(of: query) { _, _ in highlighted = 0 }
                .onKeyPress { press in handle(press) }

            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            optionRow(row, isHighlighted: index == highlighted)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(row.value) }
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: highlighted) { _, new in
                    guard rows.indices.contains(new) else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(rows[new].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1)))
        .shadow(radius: 20, y: 6)
        .onAppear { fieldFocused = true }
    }

    private func optionRow(
        _ row: (id: String, title: String, subtitle: String?, symbol: String?, tint: Color?, value: Value),
        isHighlighted: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(row.tint ?? .secondary)
                    .frame(width: 14)
            } else if let tint = row.tint {
                Circle().fill(tint).frame(width: 8, height: 8).frame(width: 14)
            }
            Text(row.title)
            if let subtitle = row.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isHighlighted ? Color.accentColor.opacity(0.22) : .clear)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            highlighted = max(0, highlighted - 1)
            return .handled
        case .downArrow:
            highlighted = min(max(0, rows.count - 1), highlighted + 1)
            return .handled
        case .return:
            if rows.indices.contains(highlighted) { onPick(rows[highlighted].value) }
            return .handled
        case .escape:
            onCancel()
            return .handled
        default:
            return .ignored
        }
    }
}
