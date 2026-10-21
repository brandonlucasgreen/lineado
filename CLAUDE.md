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

Tests are Swift Testing (`@Test` / `#expect`), in `Tests/`. 95 of them, all
over pure functions — there is no UI test and no network test. When a rule
lives in a view (the filter focus bands), the test reimplements the rule
rather than instantiating `AppState`, which would need a Keychain and a run
loop.

## Thirteen things this codebase already learned

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

### 8. `MenuBarExtra` cannot be opened from code — so the app does not use it

A global hotkey cannot open a SwiftUI `MenuBarExtra` panel on this macOS. Four
measurements, after two wrong theories (one of them blamed Control-click
modifiers; it was wrong):

- The handler **fires** — ten traced presses, ten firings.
- The `NSStatusBarButton` **is** found, and it is the right one: of the eleven
  `NSStatusBarWindow`s the system creates, exactly one is on screen and carries
  our title; the other ten are empty placeholders at y=-39.
- That button has **`target == nil` and `action == nil`**, so `performClick`
  has nothing to dispatch.
- Synthesising a mouse event with `sendEvent` **hangs the app**: a status
  item's mouse-down enters a modal tracking run loop waiting for the matching
  mouse-up, so delivering the down synchronously blocks the main thread inside
  that loop (confirmed with `sample`). Posting both to the queue avoids the
  hang and still does not open the panel.

So `MenuBarController` owns the `NSStatusItem` and an `NSPanel` directly.

**Do not "measure" the panel by counting `NSStatusBarWindow`s.** They persist
once built, so the count is high whether the panel is shown or hidden — a bad
metric that made a failure look like a success here for one whole round.

A related SwiftUI fact, no longer load-bearing but worth keeping: a `.task` on
a `MenuBarExtra` label is cancelled on every re-render, because the label
displays the very count it depends on. The icon is now kept current by
`withObservationTracking`, which no view lifecycle can cancel.

### 9. A menu bar app quits when its last window closes

AppKit terminates the process when the last visible window is ordered out. For
a menu bar app, having no window on screen is the normal resting state — so
dismissing the panel with `Esc` quit the whole app, and left **no crash report,
because nothing crashed**.

`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`.

Two traps found beside it:

- `NSApp.hide(nil)` is the wrong way to return focus. `MenuBarController`
  remembers `NSWorkspace.shared.frontmostApplication` when the panel opens and
  reactivates that app. Note hide was **not** the cause of the termination —
  removing it alone fixed nothing, which a probe showed before the real cause
  was found.
- **`statusItem.menu = menu` then `button.performClick(nil)` is infinitely
  recursive.** `performClick` re-invokes the button's action synchronously,
  landing back in the click handler where `NSApp.currentEvent` is still the
  same right-mouse-up. Right-clicking the icon would have blown the stack. Use
  `menu.popUp(positioning:at:in:)`.

### 10. SwiftUI will not render a Markdown heading from `AttributedString`

Both parsing modes fail, differently. `.inlineOnlyPreservingWhitespace`
ignores block syntax, so `### Heading` renders as literal hashes. `.full`
parses blocks into `presentationIntent` runs that `Text` declines to style, so
the hashes vanish and the line looks like every other line — worse.

`UI/MarkdownText.swift` parses blocks line by line and renders each as its own
styled view, keeping `AttributedString` for inline syntax only. `MarkdownTests`
covers the grammar, including the two traps: the space after `#` is required so
`#hashtag` stays text, and a code fence swallows its contents so `# comment`
inside a shell snippet is not a heading.

### 11. The test target aliases `Issue`, which shadows Swift Testing's

`Tests/OrderingTests.swift` declares `typealias Issue = Lineado.Issue` so tests
can say `Issue` and mean the app's type. That shadows `Testing.Issue`, so
recording a failure manually needs the full name: `Testing.Issue.record(...)`.

### 12. CI's SDK is older than yours, and Swift 6 notices

The first CI runs failed on code that compiled locally: a `@Sendable` closure
captured an `ISO8601DateFormatter`, which only newer SDKs mark `Sendable`, and
GitHub's `macos-15` runner ships an older one. Under strict concurrency an SDK's
`Sendable` annotations are part of the language surface, so a local Xcode beta
is not evidence CI will pass. Prefer value types that have always been
`Sendable` (`Date.ISO8601FormatStyle`). CI selects the newest Xcode on the image
and prints its version.

### 13. Nothing from a real workspace goes into a committed file

Design work read the real Linear workspace, and real issue titles and a project
name were copied into `PLAN.md`, a model comment and a test as examples — then
had to be scrubbed from history before the repo could go public. Keep the
numbers and shapes; invent the names (`CORE-1234`, "Website Refresh").

## Architecture

- **No database.** Linear owns the data; every issue has a canonical remote
  record. Persistence is one JSON cache for cold start, one tiny JSON map of
  local hide-until dates, and `UserDefaults`. That removes schema migration,
  uniqueness, purge policy and resurrect logic in one stroke. If offline
  mutation queueing is ever wanted, that is the moment to revisit — not before.
- `Linear/LinearClient.swift` — transport. Typed failures, because "Linear isn't
  working" is four different bugs and the panel has to say which.
- `Linear/LinearMapper.swift` — wire → domain, `nonisolated` and pure.
- `Sync/LinearService.swift` — the fetches and the four writes, **one instance
  per workspace**. Pages to completion; a truncated task list hides work
  without saying so.
- `Models/Workspace.swift` — a workspace and its credential. Each workspace
  succeeds or fails on its own in `AppState.refresh`: a revoked key carries
  that workspace's previous issues over rather than blanking the list. Linear
  ids are UUIDs so nothing collides across workspaces — except the *human*
  identifier, since `CORE-123` can exist in two.
- `Sync/AppState.swift` — `@MainActor @Observable`, everything on screen.
  `AppState+Mutations.swift` is the write path, split only for readability.
- `Models/Ordering.swift` — all grouping, sorting and filtering, as
  `nonisolated static` pure functions. This is where the tests live.
- `UI/KeyInput.swift` — `KeyMap.action(for:modifiers:isSearching:)` is the one
  place that decides what a key does. The panel and the menu bar both ask it, so
  they cannot drift apart. The whole map is documented in a table on `KeyMap`,
  and a test fails if two bindings produce the same action.
- `KeyMap.bindings` — the **only** list of keys the UI advertises. The hint bar
  and the full shortcut list render from it, and `advertisedBindingsResolve`
  pushes every entry through the real resolver. Never hand-write a key label
  anywhere else: the hint bar once did, the audit moved due date from `T` to
  `D`, and the bar went on advertising `T` — which typed into the filter.
- `UI/MenuBarController.swift` — owns the `NSStatusItem` and the `NSPanel`.
  There is no `MenuBarExtra` scene; see trap 8.
- `Support/LoginItem.swift` — Open at Login via `SMAppService`. Three states,
  not two: registration can succeed while macOS parks the item awaiting the
  user's approval.

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

## Four more macOS facts that shaped the app

- **A `.titled` panel reserves its title bar height** even with the bar hidden
  and transparent and `.fullSizeContentView` set — a band of dead space above
  the content. `MenuBarController.makePanel` uses `.borderless`, so the
  reservation cannot exist. The cost: a borderless window refuses key status
  by default (hence `KeyablePanel.canBecomeKey`, without which no text field
  in the panel takes a keystroke) and draws no background, corners or border,
  so the SwiftUI root supplies all three.
- **An `LSUIElement` app is never "active"**, so a window it opens is ordered
  into a layer behind whatever the user was looking at. `SettingsWindow.open`
  closes the panel, activates the app, and orders the window front — on the
  *next* runloop turn, because the window does not exist until `openSettings()`
  returns.
- **Reinstalling into `/Applications` likely triggers an App Management
  prompt** — every `scripts/install-local.sh` run deletes and replaces the
  bundle, and macOS asks whether the process doing it may modify an installed
  app. Brandon saw a prompt on every "reload". Unconfirmed (the TCC log redacts
  client names), but the Keychain was ruled out: the designated requirement is
  the bundle id plus the Developer ID anchor, identical on every build. Don't
  reinstall more often than a change needs, and never touch the user's security
  settings to make it stop.
- **Keychain ACLs are keyed to the code signature, not the bundle id.** An
  ad-hoc-signed debug build reading a key the Developer ID build saved prompts
  the user for their login keychain password. Build Release with the real
  identity when touching anything that reads the Keychain, and if a prompt
  appears tell the user to click **Deny**, never "Always Allow".

## What has and has not run against a live key

**The read path has**, against Brandon's real workspace: the poll lands, the
issue count matches Linear's own view, the organization name comes back, and
the single-key migration into the multi-workspace shape was verified end to
end (key moved, legacy item removed, 53 issues loaded and stamped).

**One write has**: clearing a due date, confirmed by Brandon 2026-10-20. That
is the case `JSONValue` exists for — an explicit JSON `null`, which a
`[String: String]` map could not express — so the variables encoding is proven.

**Status, priority, setting a due date and comment have not.** Before trusting
them:

1. Exercise each remaining write once.
2. With two workspaces configured, write to an issue in **each**. Mutations
   route through `service(for: issue)`; a write on the wrong workspace's key
   would 404 or hit an unrelated issue. That routing is guarded but untested.
3. Measure the complexity cost of the 100-node query — Linear rate-limits by
   complexity, not request count. The fallback is moving `labels` out of the
   list query and fetching them with the detail. This is now N queries per
   poll, one per workspace.

Say plainly in any PR which of these you did and which you did not.
