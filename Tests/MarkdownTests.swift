import Foundation
import Testing

@testable import Lineado

/// The block grammar, as a table.
///
/// `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace` leaves
/// `### Heading` as literal hashes, and with `.full` it parses blocks SwiftUI's
/// `Text` then declines to style — so the hashes vanish and the line looks like
/// every other line, which is worse. Hence a real block parser, and hence this.
@Suite("Markdown blocks")
struct MarkdownBlockTests {

    @Test("Headings, one to six")
    func headings() {
        #expect(MarkdownBlock.parse("# Big") == [.heading(level: 1, text: "Big")])
        #expect(MarkdownBlock.parse("### Small") == [.heading(level: 3, text: "Small")])
        #expect(MarkdownBlock.parse("###### Tiny") == [.heading(level: 6, text: "Tiny")])
    }

    /// The space after the hashes is required, so an issue that mentions
    /// `#2` or a `#hashtag` does not silently become a heading.
    @Test("A hash with no space is not a heading")
    func hashWithoutSpace() {
        #expect(MarkdownBlock.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownBlock.parse("####### too many") == [.paragraph("####### too many")])
    }

    @Test("Bullets, with all three markers")
    func bullets() {
        #expect(MarkdownBlock.parse("- one") == [.bullet(depth: 0, text: "one")])
        #expect(MarkdownBlock.parse("* two") == [.bullet(depth: 0, text: "two")])
        #expect(MarkdownBlock.parse("+ three") == [.bullet(depth: 0, text: "three")])
    }

    @Test("Indentation becomes nesting depth")
    func nesting() {
        #expect(MarkdownBlock.parse("  - nested") == [.bullet(depth: 1, text: "nested")])
        #expect(MarkdownBlock.parse("    - deeper") == [.bullet(depth: 2, text: "deeper")])
    }

    /// Every task item is also a bullet, so the bullet branch would swallow
    /// them if it ran first.
    @Test("Task items beat bullets")
    func taskItems() {
        #expect(MarkdownBlock.parse("- [ ] todo") == [.task(done: false, text: "todo")])
        #expect(MarkdownBlock.parse("- [x] done") == [.task(done: true, text: "done")])
        #expect(MarkdownBlock.parse("- [X] done") == [.task(done: true, text: "done")])
    }

    @Test("Numbered lists, dot or paren")
    func numbered() {
        #expect(MarkdownBlock.parse("1. first") == [.numbered(depth: 0, number: 1, text: "first")])
        #expect(MarkdownBlock.parse("2) second") == [.numbered(depth: 0, number: 2, text: "second")])
        // A bare number is a sentence, not a list.
        #expect(MarkdownBlock.parse("2026 was a year") == [.paragraph("2026 was a year")])
    }

    @Test("Quotes and rules")
    func quotesAndRules() {
        #expect(MarkdownBlock.parse("> quoted") == [.quote("quoted")])
        #expect(MarkdownBlock.parse("---") == [.rule])
        #expect(MarkdownBlock.parse("***") == [.rule])
    }

    /// A fence has to swallow its contents, or `# comment` inside a shell
    /// snippet renders as a heading.
    @Test("Fenced code is not interpreted")
    func fencedCode() {
        let source = """
            ```
            # not a heading
            - not a bullet
            ```
            """
        #expect(MarkdownBlock.parse(source) == [.code("# not a heading\n- not a bullet")])
    }

    /// Linear descriptions get truncated mid-document often enough to matter.
    @Test("An unterminated fence is still code")
    func unterminatedFence() {
        #expect(MarkdownBlock.parse("```\nlet x = 1") == [.code("let x = 1")])
    }

    @Test("Consecutive lines join into one paragraph, blank lines split them")
    func paragraphs() {
        let source = "one\ntwo\n\nthree"
        #expect(MarkdownBlock.parse(source) == [.paragraph("one two"), .paragraph("three")])
    }

    @Test("A realistic Linear description parses end to end")
    func realistic() {
        let source = """
            ### Context

            We need to **replace** the composer.

            - [x] Spike the API
            - [ ] Build the drawer

            > Blocked on design.
            """
        #expect(MarkdownBlock.parse(source) == [
            .heading(level: 3, text: "Context"),
            .paragraph("We need to **replace** the composer."),
            .task(done: true, text: "Spike the API"),
            .task(done: false, text: "Build the drawer"),
            .quote("Blocked on design."),
        ])
    }

    @Test("Empty input produces nothing")
    func empty() {
        #expect(MarkdownBlock.parse("") == [])
        #expect(MarkdownBlock.parse("\n\n  \n") == [])
    }
}
