# Lineado — working notes for agents

Native macOS menu bar app (macOS 15+, SwiftUI, Swift 6) that shows the Linear
issues assigned to you as a sortable, groupable to-do list and lets you act on
them without opening Linear.

`PLAN.md` is the design source of truth. This file is the operating manual: the
things that have actually bitten, and the conventions to keep.

Sibling project: `../inbox-and-chill`. Lineado borrows its shape and its release
pipeline. Its `CLAUDE.md` is worth reading before changing anything about
signing, Sparkle or distribution — those sections apply here almost verbatim.

## Reporting to Brandon

Short, direct, accurate. He reads on mobile, so wide tables and long code lines
hide their most important words off-screen to the right — put the point in the
first few words of a line.

- **Verify before asserting.** State what you checked and how. If you did not
  check it, say so. A confident wrong answer costs more than a slow one.
- **Don't narrate the work.** Report the finding and what it means. Skip the
  route you took to it unless the route *is* the finding.
- **One correction, then move on.** No re-litigating, no tallying your own
  mistakes, no apologising twice.
- **Separate severities.** "This is broken", "this is a latent risk" and "this
  turned out fine" must not be delivered at the same volume.

## Commands

```bash
xcodegen generate                        # after editing project.yml
xcodebuild -project Lineado.xcodeproj -scheme Lineado -configuration Debug test
scripts/check-shell.sh                   # what CI runs on scripts/
scripts/install-local.sh                 # Release → /Applications → launch
scripts/verify-bundle.sh                 # audit a built .app
scripts/sparkle-keys.sh                  # ONE TIME: create the signing key
```

Tests are Swift Testing (`@Test` / `#expect`), in `Tests/`. 58 of them, all
over pure functions — there is no UI test and no network test.

## Ten things this codebase already learned

### 1. Swift's synthesised `Decodable` ignores your default values

`var identifier: String = ""` does **not** mean "empty if the key is missing".
The synthesised initialiser throws `keyNotFound`, and one missing key fails the
whole decode — which here is the whole poll, and so the whole list.

Every field in `LinearTypes.swift` is therefore `Optional`, and `LinearMapper`
supplies the defaults. Optionals are the one shape the synthesised initialiser
treats as "absent is fine". A *type mismatch* still throws, deliberately.

`missingFieldsSurvive` in `LinearAPITests.swift` pins this. Do not "tidy" those
optionals away.

### 2. `set -o pipefail` plus `grep -q` is a trap

`grep -q` exits the instant it matches. The producer then takes SIGPIPE on its
next write, and `pipefail` reports the pipeline as failed *however well the
match went*. This made `verify-bundle.sh` report "hardened runtime not enabled"
on a bundle that plainly had it, and made the entitlements check beside it a
coin flip that happened to land right.

Capture into a variable first, then match:

```bash
signature="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
printf '%s' "$signature" | grep -q "flags=.*runtime"
```

### 3. Linear has seven workflow state types, not six

`triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled`, and
**`duplicate`** — verified 2026-10-20 against the live workspace, where Core UX
has a "Duplicate" state typed `duplicate`. All three terminal types must be in
the assigned-issues query's `nin` list, or duplicates sit on the list forever.

`StateType` decodes leniently into `.unknown` for anything new, because Linear
adds types and an enum that failed to decode one would take the poll down.

### 4. Linear's priority scale is in the wrong order for sorting

`0 = No priority, 1 = Urgent, 2 = High, 3 = Medium, 4 = Low`. Sorting on the raw
integer opens the list on every unprioritised issue, which is most of them.
`Priority.sortRank` maps None to 5. Never sort on `rawValue`.

Display uses the API's own `priorityLabel`, not a local table — Inbox & Chill's
`LinearGraphQL.swift` calls priority 3 "normal" where Linear calls it "Medium",
and that is exactly the drift this avoids.

Also: `Priority.none` collides with `Optional.none`. In a test,
`someOptionalPriority == .none` compiles and means **nil**. Write
`== Priority.none`.

### 5. Variables are `[String: JSONValue]`, and that is not negotiable

Inbox & Chill types GraphQL variables `[String: String]`, with a comment saying
every argument it sends is an id or a timestamp. True there, false here:

- `issueUpdate(input: { priority: })` takes an `Int`; a quoted `"2"` is a type
  error, not a coercion.
- **Clearing a due date needs an explicit JSON `null`.** A `[String: String]`
  map cannot express that — it can only omit the key, and an omitted key in
  `issueUpdate` means "leave unchanged". On that map, "clear the due date" and
  "do nothing" are the same request.

`JSONValueTests` pins both. Do not simplify the type back.

### 6. Reversing a sort must not promote the things with no sort key

A comparator that reports "nil is greater" inverts along with everything else
when you flip the direction, so a descending due-date sort opens on forty
undated issues. `Ordering.partition` splits them off *before* direction is
applied. "No date" is the absence of a sort key, not an extreme value of one.

### 7. `layoutPriority` does not stop a view wrapping — `fixedSize` does

SwiftUI resolves a crowded `HStack` by compressing the **narrowest** views
first. Priority decides who gives up space, not whether a view may wrap, so a
high-priority title still squeezed the status pill below its text width and the
pill wrapped one letter per line: seven-line-tall rows reading "B a c k l o g".

`IssueRowView` therefore allows exactly **one** flexible element — the title,
which truncates — and `fixedSize()`s everything else. It also hides chrome the
group header already carries: grouping by status drops the pill, grouping by
priority drops the icon. On a 460pt panel that is the difference between a
readable title and an ellipsis.

### 8. A `.task` on the `MenuBarExtra` label is cancelled on every re-render

`.task` is tied to view identity, and the label displays the issue count — so
it re-renders whenever the count changes, cancelling the task each time. A
4-second probe in there never fired once.

`app.start()` survives only because it is fire-and-forget: it stores its own
`Task` and guards re-entry, so killing the launcher does not kill the loop.
Anything that must run to completion belongs outside the view.

The loop is on the label rather than in `PanelView` for the related reason that
`MenuBarExtra(.window)` builds its **content** lazily — on first click — and
tears it down on close, so a loop owned by the panel runs only while the panel
is open, which is exactly when the count does not need to be live.

## Architecture

- **No database.** Linear owns the data; every issue has a canonical remote
  record. Persistence is one JSON cache for cold start, one tiny JSON map of
  local hide-until dates, and `UserDefaults`. That removes schema migration,
  uniqueness, purge policy and resurrect logic in one stroke. If offline
  mutation queueing is ever wanted, that is the moment to revisit — not before.
- `Linear/LinearClient.swift` — transport. Typed failures, because "Linear isn't
  working" is four different bugs and the panel has to say which.
- `Linear/LinearMapper.swift` — wire → domain, `nonisolated` and pure.
- `Sync/LinearService.swift` — the fetches and the four writes. Pages to
  completion; a truncated task list hides work without saying so.
- `Sync/AppState.swift` — `@MainActor @Observable`, everything on screen.
  `AppState+Mutations.swift` is the write path, split only for readability.
- `Models/Ordering.swift` — all grouping, sorting and filtering, as
  `nonisolated static` pure functions. This is where the tests live.
- `UI/KeyInput.swift` — `KeyMap.action(for:modifiers:isSearching:)` is the one
  place that decides what a key does. The panel and the menu bar both ask it, so
  they cannot drift apart.

### The optimistic-update guard

Every write applies locally first, then fires. `Issue.pendingUntil` marks the
issue for 15s, and `AppState.merge` skips remote fields for pending issues.
Without it, a 60s poll that started before your keystroke lands after it and
visibly reverts a change that actually succeeded.

A failed write reverts **and** leaves an inline error on the row. Nothing is
dropped silently.

### What `E` depends on

`E` resolves the issue's **own team's** completed state, from the workflow-state
cache. Statuses are per-team — Brandon is assigned across seven teams — so a
workspace-wide list would offer states the mutation rejects. If the cache is
cold, `E` says so rather than quietly doing nothing.

## Scope — what this app does not do

Lineado is a task list with write-through, not a Linear client (PLAN §2). No
creating issues, no assigning to others, no editing titles, no boards, no cycle
planning. Four writes only: status, priority, due date, comment.

`QueryTests.scopeBoundary` asserts no mutation document contains `issueCreate`,
`issueDelete`, `issueArchive` or `assigneeId`. That test is the boundary, in
executable form. If a feature request needs it relaxed, that is a `PLAN.md`
conversation first.

### 9. SwiftUI will not render a Markdown heading from `AttributedString`

Both parsing modes fail, differently. `.inlineOnlyPreservingWhitespace`
ignores block syntax, so `### Heading` renders as literal hashes. `.full`
parses blocks into `presentationIntent` runs that `Text` declines to style, so
the hashes vanish and the line looks like every other line — worse.

`UI/MarkdownText.swift` parses blocks line by line and renders each as its own
styled view, keeping `AttributedString` for inline syntax only. `MarkdownTests`
covers the grammar, including the two traps: the space after `#` is required so
`#hashtag` stays text, and a code fence swallows its contents so `# comment`
inside a shell snippet is not a heading.

### 10. The test target aliases `Issue`, which shadows Swift Testing's

`Tests/OrderingTests.swift` declares `typealias Issue = Lineado.Issue` so tests
can say `Issue` and mean the app's type. That shadows `Testing.Issue`, so
recording a failure manually needs the full name: `Testing.Issue.record(...)`.

## Two macOS facts that shaped the app

- **An `LSUIElement` app is never "active"**, so a window it opens is ordered
  into a layer behind whatever the user was looking at. `SettingsWindow.open`
  closes the panel, activates the app, and orders the window front — on the
  *next* runloop turn, because the window does not exist until `openSettings()`
  returns.
- **A global hotkey's modifiers are still held when its handler runs.**
  `NSStatusBarButton.performClick` reads the live modifier state, and a
  Control-click is a secondary click — so a ⌃-based shortcut synthesises what
  AppKit treats as a right-click. `PanelToggler.toggle` invokes the button's
  `target`/`action` instead, which does not read modifiers; it also defers one
  runloop turn, because a click issued synchronously inside the Carbon event
  dispatch is swallowed outright.
- **Keychain ACLs are keyed to the code signature, not the bundle id.** An
  ad-hoc-signed debug build reading a key the Developer ID build saved prompts
  the user for their login keychain password. Build Release with the real
  identity when touching anything that reads the Keychain, and if a prompt
  appears tell the user to click **Deny**, never "Always Allow".

## Still unverified

**Nothing in this repo has run against a live Linear API key.** The query shapes
are built from Linear's published documentation and a live read through the
Linear MCP; the mutations have never executed. Before trusting any write path:

1. Paste a personal API key into Settings.
2. Watch one poll land, and check the issue count against Linear's own view.
3. Measure the complexity cost of the 100-node query — Linear rate-limits by
   complexity, not request count. The fallback is moving `labels` out of the
   list query and fetching them with the detail.
4. Exercise each of the four writes once, including **clearing** a due date,
   which is the one the variables type exists for.

Say plainly in any PR which of these you did and which you did not.

### The global hotkey, through two fixes

⌃⌥L still did not work after the first fix. What is established:

- The handler **fires** — ten traced presses, ten firings. Registration and
  shortcut storage were never the problem.
- A `performClick` issued synchronously inside the Carbon event dispatch is
  swallowed. Deferring one runloop turn is necessary but was not sufficient.
- The current fix invokes the button's `target`/`action`, on the theory that
  `performClick` was arriving as a Control-click (see the macOS facts above).

**If it still fails, the next datum is whether a shortcut without Control
works** — that confirms or kills the modifier theory in one press.

`PanelDiagnostic` writes to `~/Library/Application Support/Lineado/hotkey.log`,
recording the modifier state at fire time and whether the panel opened.
**Delete it and its three call sites once a real press is confirmed to work** —
it is scaffolding, not a feature.
