import AppKit
import SwiftUI

/// One key press, independent of where it came from.
///
/// The panel receives keys from two places — a local `NSEvent` monitor and
/// SwiftUI's `onKeyPress` — and both have to reach identical behaviour. Naming
/// the input once means the handler is written once, and can be tested without
/// a window. (Ported from Inbox & Chill's `PanelKeyInput`.)
enum KeyInput: Equatable, Sendable {
    case up, down, left, right
    case enter, escape, space, backspace, tab
    case character(Character)

    /// Virtual key codes, not characters. `charactersIgnoringModifiers` gives
    /// arrows as private-use unicode scalars that vary with keyboard layout;
    /// the key codes don't.
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .enter
        case 53: self = .escape
        case 49: self = .space
        case 51, 117: self = .backspace
        case 48: self = .tab
        default:
            guard let character = event.charactersIgnoringModifiers?.first,
                  !character.isNewline
            else { return nil }
            self = .character(character)
        }
    }

    init?(_ press: KeyPress) {
        switch press.key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .return: self = .enter
        case .escape: self = .escape
        case .space: self = .space
        case .delete, .deleteForward: self = .backspace
        case .tab: self = .tab
        default:
            guard let character = press.characters.first else { return nil }
            self = .character(character)
        }
    }
}

/// Which modifiers were held. Kept separate from `KeyInput` so the same key can
/// mean two things (`↓` moves one row, `⌥↓` moves one group).
struct KeyModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let command = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let control = KeyModifiers(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ flags: NSEvent.ModifierFlags) {
        var result = KeyModifiers()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }

    init(_ flags: EventModifiers) {
        var result = KeyModifiers()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

/// What the list should do about a key press.
///
/// A pure enum rather than a closure so the whole keyboard map can be decided
/// by a `nonisolated static` function and tested as a table — which is the one
/// habit that keeps a keyboard-first app's shortcuts from drifting apart from
/// its menu items.
enum PanelAction: Hashable, Sendable {
    case moveSelection(Int)
    case moveGroup(Int)
    case open
    case toggleDetail
    case showStatusPicker
    case showPriorityPicker
    case showDuePicker
    case showCommentComposer
    case showHidePicker
    case complete
    case undo
    case copyLink
    case copyBranchName
    case refresh
    case cycleGrouping
    case cycleSort
    case toggleBacklog
    case cycleFilterChip(Int)
    case selectTeamIndex(Int)
    case focusSearch
    case showAllShortcuts
    case appendSearch(Character)
    case deleteSearchCharacter
    case escape
    case openWindow
}

enum KeyMap {
    /// The single source of truth for what a key does in the list.
    ///
    /// **The whole map, audited 2026-10-20.** Every binding is listed here and
    /// nowhere else, and `KeyMapTests.everyBindingIsUnique` walks it to prove
    /// no two keys produce the same action.
    ///
    /// | Key | Action | Mnemonic |
    /// |---|---|---|
    /// | `↑` `↓` | move selection | |
    /// | `⌥↑` `⌥↓` | previous / next group | |
    /// | `←` `→` | cycle the focused chip row | |
    /// | `↑` past the first row | step up into the chip rows | |
    /// | `⌘1`–`⌘9` | jump to team chip | |
    /// | `⏎` | open in Linear | |
    /// | `space` | expand / collapse detail | |
    /// | `S` | status | **s**tatus |
    /// | `P` | priority | **p**riority |
    /// | `D` | due date | **d**ue |
    /// | `C` | comment | **c**omment |
    /// | `E` | complete | **e**nd, as in I&C's Done |
    /// | `H` | hide until later | **h**ide |
    /// | `G` | cycle grouping | **g**roup |
    /// | `O` | cycle sorting | **o**rder |
    /// | `B` | show / hide backlog | **b**acklog |
    /// | `?` | all shortcuts | |
    /// | `⌘Z` | undo | |
    /// | `⌘C` / `⇧⌘C` | copy link / branch name | |
    /// | `⌘R` | refresh | |
    /// | `⌘F` | focus filter | |
    /// | `⌘0` | open in a window | |
    /// | `Esc` | unwind one layer | |
    /// | any other letter | start filtering | Finder behaviour |
    ///
    /// Three things the audit changed:
    ///
    /// 1. **`D` and `space` both expanded the detail.** `D` now means *due
    ///    date*, which is the obvious mnemonic and was previously `T` for no
    ///    reason beyond `D` already being taken.
    /// 2. **`⌘⏎` was a silent alias for `⏎`.** An undocumented second way to do
    ///    the same thing is a binding that cannot be learned and cannot be
    ///    relied on, so it is gone. (Inbox & Chill uses it for "open and mark
    ///    done"; here that is `E` then `⏎`, and conflating them would make a
    ///    team-visible status change one keystroke from an accidental press.)
    /// 3. **`⌘1`–`⌘9` force-unwrapped `Int(String(c))`.** `Character.isNumber`
    ///    is true for Arabic-Indic and other non-ASCII digits, which
    ///    `Int(_:)` cannot parse — a crash on a keyboard layout nobody tested.
    ///
    /// `isSearching` matters because a bare letter is ambiguous: it is a verb
    /// when the list has focus and a character when the search field does. Only
    /// the modified and navigational keys survive into search mode.
    nonisolated static func action(
        for key: KeyInput, modifiers: KeyModifiers = [], isSearching: Bool = false
    ) -> PanelAction? {
        if modifiers.contains(.command) {
            switch key {
            case .character("z"): return .undo
            case .character("c"): return modifiers.contains(.shift) ? .copyBranchName : .copyLink
            case .character("r"): return .refresh
            case .character("f"): return .focusSearch
            case .character("0"): return .openWindow
            case .character(let c) where c.isASCII && c.isNumber:
                guard let digit = c.wholeNumberValue, digit >= 1 else { return nil }
                return .selectTeamIndex(digit - 1)
            default: return nil
            }
        }

        if modifiers.contains(.option) {
            switch key {
            case .up: return .moveGroup(-1)
            case .down: return .moveGroup(1)
            default: return nil
            }
        }

        switch key {
        case .up: return .moveSelection(-1)
        case .down: return .moveSelection(1)
        case .enter: return .open
        case .escape: return .escape
        default: break
        }

        if isSearching {
            switch key {
            case .backspace: return .deleteSearchCharacter
            case .space: return .appendSearch(" ")
            case .character(let c): return .appendSearch(c)
            default: return nil
            }
        }

        switch key {
        case .space: return .toggleDetail
        // Not "cycle team": which row this walks depends on which band has
        // focus, and naming it after one of them would be a lie half the time.
        case .left: return .cycleFilterChip(-1)
        case .right: return .cycleFilterChip(1)
        case .character("?"): return .showAllShortcuts
        case .character(let c):
            switch Character(c.lowercased()) {
            case "s": return .showStatusPicker
            case "p": return .showPriorityPicker
            case "d": return .showDuePicker
            case "c": return .showCommentComposer
            case "e": return .complete
            case "h": return .showHidePicker
            case "g": return .cycleGrouping
            case "o": return .cycleSort
            case "b": return .toggleBacklog
            // Any other printable character starts a search, like the Finder.
            // That is what a Mac user tries first, and it costs one branch.
            case let other where other.isLetter || other.isNumber:
                return .appendSearch(other)
            default: return nil
            }
        default: return nil
        }
    }
}
