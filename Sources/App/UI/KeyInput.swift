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
enum PanelAction: Equatable, Sendable {
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
    case cycleTeam(Int)
    case selectTeamIndex(Int)
    case focusSearch
    case appendSearch(Character)
    case deleteSearchCharacter
    case escape
    case openWindow
}

enum KeyMap {
    /// The single source of truth for what a key does in the list.
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
            case .character(let c) where c.isNumber && c != "0":
                return .selectTeamIndex(Int(String(c))! - 1)
            case .enter: return .open
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
        case .left: return .cycleTeam(-1)
        case .right: return .cycleTeam(1)
        case .character(let c):
            switch Character(c.lowercased()) {
            case "s": return .showStatusPicker
            case "p": return .showPriorityPicker
            case "t": return .showDuePicker
            case "c": return .showCommentComposer
            case "e": return .complete
            case "h": return .showHidePicker
            case "d": return .toggleDetail
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
