import SwiftUI

/// Renders Linear's Markdown as actual rich text.
///
/// `AttributedString(markdown:)` is not enough on its own. With
/// `.inlineOnlyPreservingWhitespace` it ignores block syntax entirely, so a
/// `### Heading` renders as the literal characters `### Heading`. With `.full`
/// it *parses* blocks into `presentationIntent` runs, but SwiftUI's `Text`
/// does not style them — the hashes disappear and the line comes out looking
/// like every other line, which is arguably worse.
///
/// So blocks are parsed here, line by line, and each one is rendered as its own
/// styled view; inline syntax (`**bold**`, `` `code` ``, links) still goes
/// through `AttributedString`, which handles it well.
///
/// Scope is deliberately Linear's own writing: headings, bullets, numbered
/// lists, quotes, fenced code, rules, and task list items. Tables and nested
/// lists fall back to their source text rather than being silently mangled.
struct MarkdownText: View {
    let raw: String
    var lineLimitPerBlock: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(MarkdownBlock.parse(raw).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                // Three sizes for six levels: past `###` the distinctions stop
                // meaning anything inside a panel this narrow.
                .font(.system(size: level <= 1 ? 15 : (level == 2 ? 13.5 : 12.5),
                              weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 3)

        case .paragraph(let text):
            Text(inline(text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimitPerBlock)

        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Text(inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimitPerBlock)
            }
            .padding(.leading, CGFloat(depth) * 12)

        case .numbered(let depth, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimitPerBlock)
            }
            .padding(.leading, CGFloat(depth) * 12)

        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.caption)
                    // Both branches must be the same concrete type: `.tertiary`
                    // is a HierarchicalShapeStyle, not a Color, so a ternary
                    // with Color.accentColor cannot unify.
                    .foregroundStyle(done ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                Text(inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .strikethrough(done, color: Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(lineLimitPerBlock)
            }

        case .quote(let text):
            Text(inline(text))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .italic()
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2)
                }

        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// Inline syntax only — bold, italic, code spans, links. Falls back to the
    /// raw text rather than to nothing when a line will not parse.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// One parsed block of Markdown.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(depth: Int, number: Int, text: String)
    case task(done: Bool, text: String)
    case quote(String)
    case code(String)
    case rule

    /// Splits a Markdown document into blocks.
    ///
    /// `nonisolated` and pure, so the whole grammar is testable as a table
    /// without rendering anything.
    nonisolated static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence swallows everything until it closes, so markup inside a
            // code block is never interpreted.
            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inFence = false
                } else {
                    flushParagraph()
                    inFence = true
                }
                continue
            }
            if inFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let block = blockLine(trimmed, indent: indentWidth(of: line)) {
                flushParagraph()
                blocks.append(block)
                continue
            }

            paragraph.append(trimmed)
        }

        // An unterminated fence is still code — Linear descriptions get
        // truncated mid-document often enough to matter.
        if inFence, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private nonisolated static func blockLine(_ trimmed: String, indent: Int) -> MarkdownBlock? {
        // `---`, `***`, `___`
        if trimmed.count >= 3,
           trimmed.allSatisfy({ $0 == "-" }) || trimmed.allSatisfy({ $0 == "*" })
               || trimmed.allSatisfy({ $0 == "_" }) {
            return .rule
        }

        // `# ` … `###### `. The space is required, so a bare `#tag` stays text.
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if hashes <= 6 {
                let rest = String(trimmed.dropFirst(hashes))
                if rest.hasPrefix(" ") {
                    return .heading(level: hashes,
                                    text: rest.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        if trimmed.hasPrefix("> ") {
            return .quote(String(trimmed.dropFirst(2)))
        }

        // Task items are checked before plain bullets, because every task item
        // is also a bullet and the bullet branch would swallow it.
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let rest = String(trimmed.dropFirst(marker.count))
            let lowered = rest.lowercased()
            if lowered.hasPrefix("[ ] ") {
                return .task(done: false, text: String(rest.dropFirst(4)))
            }
            if lowered.hasPrefix("[x] ") {
                return .task(done: true, text: String(rest.dropFirst(4)))
            }
            return .bullet(depth: indent / 2, text: rest)
        }

        // `1. `, `2) `
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3, let number = Int(digits) {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .numbered(depth: indent / 2, number: number,
                                 text: String(rest.dropFirst(2)))
            }
        }

        return nil
    }

    /// Leading spaces, with a tab counting as two.
    private nonisolated static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 2 } else { break }
        }
        return width
    }
}
