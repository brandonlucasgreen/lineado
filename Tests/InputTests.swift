import Foundation
import Testing

@testable import Lineado

// MARK: - Dates

@Suite("Calendar dates")
struct CalendarDateTests {

    @Test("Round-trips through the wire format")
    func roundTrip() {
        let date = CalendarDate(year: 2026, month: 11, day: 5)
        #expect(date.wireValue == "2026-11-05")
        #expect(CalendarDate(wireValue: "2026-11-05") == date)
    }

    /// Linear returns `dueDate` as a bare date, but `targetDate` has been seen
    /// both ways; taking the date part costs one line and removes the question.
    @Test("A full ISO timestamp parses to its date part")
    func parsesTimestamp() {
        #expect(CalendarDate(wireValue: "2026-11-05T00:00:00.000Z")
                == CalendarDate(year: 2026, month: 11, day: 5))
    }

    @Test("Garbage does not parse")
    func rejectsGarbage() {
        for bad in ["", "not-a-date", "2026-13-01", "2026-11-99", "2026/11/05"] {
            #expect(CalendarDate(wireValue: bad) == nil, "should reject \(bad)")
        }
    }

    @Test("Comparison is chronological, not lexical")
    func comparison() {
        #expect(CalendarDate(year: 2026, month: 9, day: 30) < CalendarDate(year: 2026, month: 10, day: 1))
        #expect(CalendarDate(year: 2025, month: 12, day: 31) < CalendarDate(year: 2026, month: 1, day: 1))
    }
}

@Suite("Typed date parsing")
struct DateParsingTests {
    // A Wednesday, so weekday arithmetic has a known answer.
    let today = CalendarDate(year: 2026, month: 10, day: 21)

    @Test("Words you would actually type")
    func words() {
        #expect(DateParsing.parse("today", today: today) == .date(today))
        #expect(DateParsing.parse("tomorrow", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 22)))
        #expect(DateParsing.parse("TOM", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 22)))
    }

    @Test("Clearing has several spellings, because all of them get typed")
    func clearing() {
        for text in ["none", "clear", "-", "never", "NO DATE"] {
            #expect(DateParsing.parse(text, today: today) == .clear, "should clear on \(text)")
        }
    }

    @Test("Relative offsets, with a bare number meaning days")
    func offsets() {
        #expect(DateParsing.parse("+3d", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 24)))
        #expect(DateParsing.parse("3d", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 24)))
        #expect(DateParsing.parse("7", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 28)))
        #expect(DateParsing.parse("2w", today: today)
                == .date(CalendarDate(year: 2026, month: 11, day: 4)))
    }

    /// Typing "wednesday" on a Wednesday means the one coming — otherwise the
    /// word is a slower way to type "today".
    @Test("A weekday means the next one, never today")
    func weekdays() {
        #expect(DateParsing.parse("fri", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 23)))
        #expect(DateParsing.parse("wednesday", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 28)))
        #expect(DateParsing.parse("mon", today: today)
                == .date(CalendarDate(year: 2026, month: 10, day: 26)))
    }

    @Test("Explicit dates, numeric and named")
    func explicit() {
        #expect(DateParsing.parse("2026-11-05", today: today)
                == .date(CalendarDate(year: 2026, month: 11, day: 5)))
        #expect(DateParsing.parse("5 nov", today: today)
                == .date(CalendarDate(year: 2026, month: 11, day: 5)))
        #expect(DateParsing.parse("nov 5", today: today)
                == .date(CalendarDate(year: 2026, month: 11, day: 5)))
    }

    @Test("A month/day already past rolls into next year")
    func rollsForward() {
        #expect(DateParsing.parse("1 jan", today: today)
                == .date(CalendarDate(year: 2027, month: 1, day: 1)))
        #expect(DateParsing.parse("25 dec", today: today)
                == .date(CalendarDate(year: 2026, month: 12, day: 25)))
    }

    /// Calendar would silently normalise 31 February to 3 March. A due date you
    /// did not pick is worse than an error.
    @Test("Impossible dates are rejected, not normalised")
    func rejectsImpossible() {
        #expect(DateParsing.parse("31 feb", today: today) == nil)
        #expect(DateParsing.parse("2026-02-30", today: today) == nil)
    }

    @Test("Nonsense parses to nothing")
    func nonsense() {
        for text in ["", "   ", "banana", "??"] {
            #expect(DateParsing.parse(text, today: today) == nil, "should not parse \(text)")
        }
    }
}

// MARK: - Keyboard

@Suite("Keyboard map")
struct KeyMapTests {

    /// The map is a table so the panel and the menu bar cannot drift apart:
    /// both ask this function what a key means.
    @Test("The single-letter verbs")
    func verbs() {
        #expect(KeyMap.action(for: .character("s")) == .showStatusPicker)
        #expect(KeyMap.action(for: .character("p")) == .showPriorityPicker)
        #expect(KeyMap.action(for: .character("d")) == .showDuePicker)
        #expect(KeyMap.action(for: .character("c")) == .showCommentComposer)
        #expect(KeyMap.action(for: .character("e")) == .complete)
        #expect(KeyMap.action(for: .character("h")) == .showHidePicker)
        #expect(KeyMap.action(for: .character("b")) == .toggleBacklog)
        #expect(KeyMap.action(for: .character("g")) == .cycleGrouping)
        #expect(KeyMap.action(for: .character("o")) == .cycleSort)
    }

    @Test("Verbs are case-insensitive, because shift-lock exists")
    func caseInsensitive() {
        #expect(KeyMap.action(for: .character("E")) == .complete)
        #expect(KeyMap.action(for: .character("S")) == .showStatusPicker)
    }

    @Test("Option-arrow jumps a group, plain arrow jumps a row")
    func groupNavigation() {
        #expect(KeyMap.action(for: .down) == .moveSelection(1))
        #expect(KeyMap.action(for: .up) == .moveSelection(-1))
        #expect(KeyMap.action(for: .down, modifiers: .option) == .moveGroup(1))
        #expect(KeyMap.action(for: .up, modifiers: .option) == .moveGroup(-1))
    }

    @Test("Command shortcuts")
    func commandKeys() {
        #expect(KeyMap.action(for: .character("z"), modifiers: .command) == .undo)
        #expect(KeyMap.action(for: .character("c"), modifiers: .command) == .copyLink)
        #expect(KeyMap.action(for: .character("c"), modifiers: [.command, .shift]) == .copyBranchName)
        #expect(KeyMap.action(for: .character("r"), modifiers: .command) == .refresh)
        #expect(KeyMap.action(for: .character("0"), modifiers: .command) == .openWindow)
        #expect(KeyMap.action(for: .character("3"), modifiers: .command) == .selectTeamIndex(2))
    }

    /// A bare letter is a verb when the list has focus and a character when the
    /// search field does. Getting this backwards means typing "e" into a search
    /// box completes a task.
    @Test("In search mode letters type instead of acting")
    func searchModeSwallowsVerbs() {
        #expect(KeyMap.action(for: .character("e"), isSearching: true) == .appendSearch("e"))
        #expect(KeyMap.action(for: .character("s"), isSearching: true) == .appendSearch("s"))
        #expect(KeyMap.action(for: .backspace, isSearching: true) == .deleteSearchCharacter)
        // Navigation still has to work while searching.
        #expect(KeyMap.action(for: .down, isSearching: true) == .moveSelection(1))
        #expect(KeyMap.action(for: .enter, isSearching: true) == .open)
        #expect(KeyMap.action(for: .escape, isSearching: true) == .escape)
    }

    /// Finder behaviour: an unassigned letter starts a search rather than
    /// doing nothing. It is what a Mac user tries first.
    @Test("An unassigned letter starts a search")
    func typeToSearch() {
        #expect(KeyMap.action(for: .character("z")) == .appendSearch("z"))
        #expect(KeyMap.action(for: .character("8")) == .appendSearch("8"))
    }

    @Test("Space toggles the detail, left and right walk the team chips")
    func panelKeys() {
        #expect(KeyMap.action(for: .space) == .toggleDetail)
        #expect(KeyMap.action(for: .left) == .cycleTeam(-1))
        #expect(KeyMap.action(for: .right) == .cycleTeam(1))
        #expect(KeyMap.action(for: .character("?")) == .showAllShortcuts)
    }

    /// The audit, as a test. `D` and `space` both expanded the detail until
    /// 2026-10-20, which is the kind of thing a reader of the switch statement
    /// does not notice and a reader of this list cannot miss.
    @Test("No two bindings produce the same action")
    func everyBindingIsUnique() {
        let keys: [(KeyInput, KeyModifiers)] = [
            (.up, []), (.down, []), (.left, []), (.right, []),
            (.up, .option), (.down, .option),
            (.enter, []), (.space, []), (.escape, []),
            (.character("?"), []),
            (.character("s"), []), (.character("p"), []), (.character("d"), []),
            (.character("c"), []), (.character("e"), []), (.character("h"), []),
            (.character("g"), []), (.character("o"), []), (.character("b"), []),
            (.character("z"), .command), (.character("c"), .command),
            (.character("c"), [.command, .shift]), (.character("r"), .command),
            (.character("f"), .command), (.character("0"), .command),
        ]

        var seen: [PanelAction: (KeyInput, KeyModifiers)] = [:]
        for (key, modifiers) in keys {
            guard let action = KeyMap.action(for: key, modifiers: modifiers) else {
                Testing.Issue.record("\(key) has no action but was listed as a binding")
                continue
            }
            if let existing = seen[action] {
                Testing.Issue.record("\(key) and \(existing.0) both produce \(action)")
            }
            seen[action] = (key, modifiers)
        }
    }

    /// `Character.isNumber` is true for Arabic-Indic and other non-ASCII
    /// digits, which `Int(String(c))` cannot parse. The old code force-
    /// unwrapped that, so a team shortcut on such a layout was a crash.
    @Test("Non-ASCII digits do not crash the team shortcut")
    func nonASCIIDigits() {
        #expect(KeyMap.action(for: .character("٣"), modifiers: .command) == nil)
        #expect(KeyMap.action(for: .character("3"), modifiers: .command) == .selectTeamIndex(2))
    }

    /// An undocumented second way to do one thing is a binding nobody can
    /// learn and nobody can rely on.
    @Test("Command-Return is not a silent alias for Return")
    func noCommandReturnAlias() {
        #expect(KeyMap.action(for: .enter, modifiers: .command) == nil)
    }
}

// MARK: - Cycling

@Suite("Cycling through options")
struct CyclingTests {

    @Test("G and O wrap at the end")
    func wraps() {
        #expect(GroupBy.allCases.next(after: GroupBy.allCases.last!) == GroupBy.allCases.first)
        #expect(SortBy.allCases.next(after: SortBy.allCases.last!) == SortBy.allCases.first)
        #expect(GroupBy.allCases.next(after: .none) == .priority)
    }
}

// MARK: - Local state

@Suite("Local state")
struct LocalStateTests {

    /// Without pruning by living id, hiding an issue that is later completed in
    /// Linear leaves its id in the file forever.
    @Test("Pruning drops expired entries and issues that no longer exist")
    func pruning() {
        var state = LocalState(hiddenUntil: [
            "alive": Date().addingTimeInterval(3600),
            "expired": Date().addingTimeInterval(-3600),
            "gone": Date().addingTimeInterval(3600),
        ])
        state.prune(livingIssueIDs: ["alive", "expired"])
        #expect(state.hiddenUntil.keys.sorted() == ["alive"])
    }
}

// MARK: - Due date rendering

@Suite("Due date rendering")
struct DueDateStyleTests {
    let today = CalendarDate(year: 2026, month: 10, day: 21)

    @Test("Near dates read relatively and alarm; far ones do not")
    func wording() {
        #expect(DueDateStyle.render(today, relativeTo: today).text == "Today")
        #expect(DueDateStyle.render(today, relativeTo: today).isAlarming)

        let yesterday = CalendarDate(year: 2026, month: 10, day: 20)
        #expect(DueDateStyle.render(yesterday, relativeTo: today).text == "Yesterday")
        #expect(DueDateStyle.render(yesterday, relativeTo: today).isAlarming)

        let overdue = CalendarDate(year: 2026, month: 10, day: 14)
        #expect(DueDateStyle.render(overdue, relativeTo: today).text == "7 days ago")

        let far = CalendarDate(year: 2026, month: 12, day: 25)
        #expect(!DueDateStyle.render(far, relativeTo: today).isAlarming)
    }
}

// MARK: - Login item

import ServiceManagement

@Suite("Open at login")
struct LoginItemTests {

    /// `requiresApproval` is the case that matters: registration *succeeded*,
    /// but macOS is waiting on the user in System Settings, so the item will
    /// not actually run at login. A toggle reading plainly "on" there would be
    /// lying, which is why it maps to its own state rather than to `.enabled`.
    @Test("Every SMAppService status maps to exactly one UI state")
    func statusMapping() {
        #expect(LoginItem.state(for: .enabled) == .enabled)
        #expect(LoginItem.state(for: .notRegistered) == .disabled)
        #expect(LoginItem.state(for: .requiresApproval) == .requiresApproval)
        #expect(LoginItem.state(for: .notFound) == .unavailable)
    }

    /// The toggle shows "on" while awaiting approval, because the user *has*
    /// asked for it — the warning beside it explains why it is not live yet.
    /// Showing it off would invite them to click it again, which does nothing.
    @Test("Awaiting approval still reads as on")
    func approvalReadsAsOn() {
        #expect(LoginItem.State.requiresApproval.isOn)
        #expect(LoginItem.State.enabled.isOn)
        #expect(!LoginItem.State.disabled.isOn)
        #expect(!LoginItem.State.unavailable.isOn)
    }
}
