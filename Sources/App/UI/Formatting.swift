import SwiftUI

/// Hex strings from Linear (`#f2c94c`) into SwiftUI colours.
extension Color {
    init?(linearHex: String?) {
        guard let linearHex else { return nil }
        var hex = linearHex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

extension Priority {
    var tint: Color {
        switch self {
        case .none: .secondary
        case .urgent: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        }
    }
}

/// How a due date reads, and whether it should alarm you.
///
/// Relative wording up close ("Today", "Tomorrow", "3 days ago") and a plain
/// date further out, because "in 47 days" is not a thing anyone needs to know.
enum DueDateStyle {
    struct Rendered {
        let text: String
        let tint: Color
        let isAlarming: Bool
    }

    static func render(_ due: CalendarDate, relativeTo today: CalendarDate = .today()) -> Rendered {
        guard let days = due.days(since: today) else {
            return Rendered(text: due.wireValue, tint: .secondary, isAlarming: false)
        }
        switch days {
        case ..<0:
            let magnitude = -days
            let text = magnitude == 1 ? "Yesterday" : "\(magnitude) days ago"
            return Rendered(text: text, tint: .red, isAlarming: true)
        case 0:
            return Rendered(text: "Today", tint: .red, isAlarming: true)
        case 1:
            return Rendered(text: "Tomorrow", tint: .orange, isAlarming: true)
        case 2...6:
            return Rendered(text: weekdayName(for: due) ?? "In \(days) days",
                            tint: .secondary, isAlarming: false)
        default:
            return Rendered(text: shortDate(due), tint: .secondary, isAlarming: false)
        }
    }

    private static func weekdayName(for date: CalendarDate) -> String? {
        guard let resolved = date.date() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: resolved)
    }

    private static func shortDate(_ date: CalendarDate) -> String {
        guard let resolved = date.date() else { return date.wireValue }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: resolved)
    }
}

extension Date {
    /// "just now", "4m ago", "2h ago" — for the footer's last-synced line.
    var shortRelative: String {
        let seconds = Date().timeIntervalSince(self)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }
}

/// What an issue puts on the pasteboard, and on a drag.
///
/// Three representations so dropping it somewhere useful just works: a URL for
/// browsers and link fields, plain text for Slack and notes, and the same text
/// as a fallback for anything that asks for a string. (PLAN §6.4 — the
/// "I wonder if that works" test.)
enum IssuePasteboard {
    static func plainText(for issue: Issue) -> String {
        "\(issue.identifier) \(issue.title) — \(issue.url)"
    }

    @MainActor
    static func copy(_ issue: Issue) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.URL, .string], owner: nil)
        if let url = URL(string: issue.url) {
            (url as NSURL).write(to: pasteboard)
        }
        pasteboard.setString(plainText(for: issue), forType: .string)
    }

    @MainActor
    static func copyBranchName(_ issue: Issue) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(issue.branchName ?? issue.identifier.lowercased(), forType: .string)
    }
}
