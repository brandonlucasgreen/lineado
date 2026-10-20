# Lineado

A native macOS menu bar app that turns the Linear issues assigned to you into a
simple, orderable to-do list — sortable, groupable, and actionable without
leaving the menu bar.

Status: **early**. Builds, signs, and runs; the read and write paths are
written but have not yet been exercised against a live Linear API key. See
[PLAN.md](PLAN.md) for the design and [CLAUDE.md](CLAUDE.md) for the traps.

## What it does

- Lists every open issue assigned to you, across every team
- Sorts by priority, due date, created or updated
- Groups by priority, status, project, milestone or team
- Acts on the selected issue with one key: change status, priority or due date,
  post a comment, complete it, or open it in Linear
- Hides an issue locally until later, without touching Linear

## What it isn't

Not a Linear client — no creating issues, no boards, no cycle planning. Not a
notification queue; that's [Inbox & Chill](https://github.com/brandonlucasgreen/inbox-and-chill),
which mirrors the Linear inbox. Lineado answers "what am I supposed to be doing?"

## Keyboard

| Key | Action |
|---|---|
| `↑` / `↓` | Move selection |
| `⌥↑` / `⌥↓` | Previous / next group |
| `⏎` | Open in Linear |
| `space` | Expand the detail — description, comments, composer |
| `S` · `P` · `T` | Status · priority · due date |
| `C` | Comment |
| `E` | Complete |
| `H` | Hide until later (locally; Linear unchanged) |
| `⌘Z` | Undo |
| `⌘C` / `⌘⇧C` | Copy link / branch name |
| `G` · `O` · `B` | Cycle grouping · sorting · show backlog |
| `←` / `→`, `⌘1`…`⌘9` | Team filter |
| type | Filter the list |
| `⌘0` | Open in a window, with the full menu bar |

## Requirements

- macOS 15 (Sequoia) or later
- A Linear personal API key — Linear → Settings → Security & access

## Building

```sh
scripts/install-local.sh
```

Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen), so the `.xcodeproj`
isn't committed. Tests: `xcodebuild -project Lineado.xcodeproj -scheme Lineado test`.
