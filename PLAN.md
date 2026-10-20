# Lineado — Plan

A native macOS menu bar app that turns the Linear issues assigned to you into a
simple, orderable to-do list you can act on without leaving the menu bar.

This file is the design source of truth. `CLAUDE.md` will be the operating
manual — the things that actually bit, and the conventions to keep.

Sibling project: [Inbox & Chill](https://github.com/brandonlucasgreen/inbox-and-chill)
(`../inbox-and-chill`). Lineado borrows its shape — menu bar panel, keyboard-first
triage, XcodeGen + Developer ID + Sparkle — and deliberately drops the parts that
only made sense for a multi-source notification queue. Where this plan says "like
I&C", the code there is the reference. Where it says "unlike I&C", the difference
is load-bearing and the reason is given.

---

## 1. The problem

Linear is where the work is recorded. It is not where you decide what to do next.

Opening Linear to see what is assigned to you means loading a web app, landing in
whatever view you left, and being shown everything — other people's issues, the
team's board, the cycle. The act of checking costs enough that you check less
often than you should, and the list you want ("what is mine, what is urgent, what
is late") is three clicks away from where you land.

You already treat Reminders and Things as the model: a flat list, sorted how you
want, acted on with one key, closed again in ten seconds. Nothing does that for
Linear *in the menu bar*. The Linear desktop app is a wrapper around the web app;
the menu bar apps that exist are notification mirrors, not task lists.

## 2. What this app is (and isn't)

**It is a task list with write-through.** Linear owns the data. Lineado shows the
subset that is yours and open, in the order you want it, and lets you change the
four fields you actually change from a list view — status, priority, due date, and
a comment — without opening Linear.

**It is not a Linear client.** No creating issues, no assigning to others, no
editing titles or descriptions, no board, no cycle planning, no sub-issue tree.
The moment a task needs real work, `⏎` deep-links you into Linear and Lineado's
job is done.

**It is not a notification queue.** That is Inbox & Chill, which already mirrors
the Linear inbox and does it well. Lineado never shows a mention, a comment
notification, or a status change. It shows *issues*, and an issue leaves the list
because its status changed — not because you dismissed it.

This boundary is the one worth defending. The two apps can sit in the same menu
bar without overlapping: I&C answers "who needs me?", Lineado answers "what am I
supposed to be doing?"

### Scoped to Linear, on purpose

I&C's value is breadth — twelve sources in one queue. Lineado's value is the
opposite: because there is exactly one backend, every affordance can be specific
to it. Priority is Linear's five-level scale, not a generic flag. Status is the
issue's own team's workflow states, not "done/not done". A plugin architecture
here would buy nothing and cost the specificity.

## 3. Mac app classification (per the Mac-arsed workflow)

**Shape:** shoebox/library app wearing a utility's clothes. The library is
remote and read-mostly; the utility is the menu bar panel that fronts it.

**Core object:** the `Issue`. Everything in the affordance map hangs off it.

| Question | Answer for `Issue` |
|---|---|
| Opened | `⏎` → `linear.app` URL in the default browser (or the Linear app, if installed and it claims the URL) |
| Saved | Never locally as a document. Changes write through to Linear. |
| Selected | Yes — single selection drives every verb. Multi-select is v2 (§9). |
| Dragged | Yes — out of the app, as URL + plain text (§6.4) |
| Copied | Yes — `⌘C`, multiple pasteboard representations (§6.4) |
| Imported/exported | No. Linear is the store. |
| Shown in multiple windows | Yes — the panel and the `⌘0` window are two views of one list |
| Persisted | Only as a cold-start cache, plus local hide-until state (§4.3) |
| Undone | Status, priority, due date — yes, `⌘Z`. Comments — no (§6.3) |

**Substrate:** SwiftUI, macOS 15+, Swift 6 strict concurrency. Same as I&C, for
the same reason: it is Apple's direction and the app is a list and some popovers.
Two places are expected to need an AppKit bridge, both of which I&C already
solved — the local `NSEvent` key monitor that makes the panel keyboard-driven
(`UI/PanelKeyInput.swift`), and `PanelToggler`, which toggles `MenuBarExtra`
presentation for the global hotkey. Copy both rather than rediscovering them.

## 4. Architecture

### 4.1 Shape

```
Sources/App/
  LineadoApp.swift            @main — MenuBarExtra + Window + Settings
  AppState.swift              @Observable root: issues, prefs, sync, errors
  Linear/
    LinearClient.swift        transport: auth, execute, typed errors
    LinearQueries.swift       the GraphQL documents, as string constants
    LinearTypes.swift         Decodable payloads
    LinearMapper.swift        nonisolated pure: payload → [Issue]
  Models/
    Issue.swift               the domain model (struct, Sendable)
    WorkflowState.swift       per-team statuses, cached
    Ordering.swift            GroupBy/SortBy + the pure ordering functions
    LocalState.swift          hide-until, keyed by issue id
  Sync/
    SyncEngine.swift          poll loop, backoff, refresh-on-open
    MutationQueue.swift       optimistic apply, rollback, undo stack
  UI/
    PanelView.swift           the menu bar panel
    IssueListView.swift       the list — shared by panel and window
    IssueRowView.swift
    IssueDetailView.swift     expanded row: description + comments + composer
    Pickers/                  StatusPicker, PriorityPicker, DueDatePicker
    KeyInput.swift            one key press, independent of its source
    Commands.swift            the real menu bar
    MainWindow/
    Settings/
  Support/
    Keychain.swift
    UpdateController.swift    Sparkle, behind one type
    IssueCache.swift          JSON snapshot for cold start
```

### 4.2 No SwiftData — and why that is the biggest simplification

I&C needs a database because its items have no remote home: it owns
done/snooze/pin/archive/purge, has to resurrect items a poll re-emits, and has to
enforce uniqueness across twelve sources. None of that applies here. Every issue
Lineado shows has a canonical record in Linear, and the only thing that removes it
from the list is Linear saying so.

So the persistence layer is three small things:

- **`IssueCache`** — the last successful snapshot as JSON in Application Support,
  written after each poll. Its only job is that opening the panel before the first
  poll completes shows yesterday's list instead of a spinner.
- **`LocalState`** — a tiny JSON map of `issueID → hiddenUntil`. The one piece of
  state Linear does not have (§4.3).
- **`UserDefaults`** — sort, group, backlog visibility, team filter, window frame.

This removes schema migration, `@ModelActor` plumbing, uniqueness constraints,
purge policy, and the resurrect logic in one stroke. If offline mutation queueing
across launches is ever wanted, that is the moment to revisit — not before.

### 4.3 Hide until later — the one piece of local state

Half your open assigned issues are Backlog or Blocked, some created in 2025. The
Backlog toggle (§5.3) handles the bulk of that, but there will always be a handful
of *active* issues you do not want to look at this week and cannot honestly move
to Backlog, because your team reads status.

`H` hides an issue locally until a date — tomorrow, next week, a picked date. It
touches nothing in Linear. A hidden issue returns on its own, and the panel footer
always says how many are hidden so the list never lies about its own completeness.

This is deliberately the *only* local state. No "Today" flag, no manual ordering —
both were considered and cut, because each introduces a second ordering authority
that fights the sort/group model and has to be reconciled on every poll.

### 4.4 Sync

- **Poll every 60s** while the app is running, and immediately when the panel
  opens or the window becomes key. Linear's personal-key budget is ~1,500
  requests/hour; this spends ~60 plus mutations and on-demand detail fetches.
- **One request per poll** for the list (§4.5), paginated if you ever cross 100
  open assigned issues. Paginate to completion — a truncated list silently hiding
  a task is the failure mode that matters here.
- **Workflow states** are fetched once at launch and hourly thereafter, into a
  cache keyed by team. The status picker cannot be drawn without them.
- **Backoff** on failure, like I&C's SyncEngine: retry at 5s, then widening, and
  surface the error in the panel rather than logging it. (I&C's rule 5 — silent
  failure is the recurring bug class — applies verbatim.)

### 4.5 The query

One document, one request:

```graphql
query AssignedIssues($after: String) {
  viewer {
    id
    assignedIssues(
      first: 100
      after: $after
      filter: { state: { type: { nin: ["completed", "canceled", "duplicate"] } } }
      orderBy: updatedAt
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id identifier title url branchName updatedAt createdAt
        priority priorityLabel dueDate
        state  { id name type color position }
        team   { id key name }
        project { id name }
        projectMilestone { id name targetDate }
        labels { nodes { id name color } }
        parent { id identifier title }
      }
    }
  }
}
```

Two of the three original unknowns are now **resolved** (2026-10-20):

1. **`duplicate` is a real `WorkflowState.type`**, distinct from `canceled`.
   Verified against the live workspace: Core UX has a "Duplicate" state typed
   `duplicate`. So Linear has **seven** state types — `triage`, `backlog`,
   `unstarted`, `started`, `completed`, `canceled`, `duplicate` — and all three
   terminal ones must be in the `nin` list. Assuming six would have left
   duplicates on the list forever.
2. **`assignee: { isMe: ... }` is not documented**, so the query does not use it.
   `viewer { assignedIssues(filter:) }` is documented, takes the same
   `IssueFilter`, pages the same way, and removes the need to resolve and cache a
   viewer id first. `state: { type: { nin: [...] } }` *is* confirmed — `type` is a
   `StringComparator` and `nin` is one of its comparators.

Still open, and Phase 1's job to measure:

3. **Query complexity, not request count, is Linear's real limit.** 100 nodes
   with two nested connections is not free. If it is too heavy, drop `labels`
   from the list query and fetch them with the detail.

Issue **detail** is a second, on-demand query, fired when a row expands and cached
until the next poll touches that issue:

```graphql
query IssueDetail($id: String!) {
  issue(id: $id) {
    description
    comments(last: 20) {
      nodes { id body createdAt url user { displayName avatarUrl } }
    }
  }
}
```

### 4.6 Mutations, and a difference from I&C that will bite

```graphql
mutation SetState(  $id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }
mutation SetPriority($id: String!, $priority: Int!)  { issueUpdate(id: $id, input: { priority: $priority }) { success } }
mutation SetDueDate( $id: String!, $dueDate: TimelessDate) { issueUpdate(id: $id, input: { dueDate: $dueDate }) { success } }
mutation AddComment( $id: String!, $body: String!)   { commentCreate(input: { issueId: $id, body: $body }) { success comment { id url } } }
```

**I&C's `GraphQLRequestBody` types its variables as `[String: String]`** — every
argument it sends is an id or an ISO timestamp, so that was enough, and there is a
comment in `LinearGraphQL.swift` saying so. It is not enough here. `priority` is
an `Int`, and *clearing* a due date requires sending an explicit JSON `null`,
which a `[String: String]` map cannot express at all — it can only omit the key,
and an omitted key in `issueUpdate` means "leave unchanged".

So Lineado's request body takes `[String: JSONValue]`, with a small `JSONValue`
enum (`.string`, `.int`, `.null`). Copy the rest of the transport from I&C's
`LinearConnector.execute` — the error enum there is good and the HTTP/GraphQL
error separation is worth keeping — but not that type.

### 4.7 Optimistic updates, rollback, and the poll-clobber guard

Every mutation applies to the local model **immediately**, animates the row, and
fires the request. On failure the change reverts and the row carries an inline
error until dismissed. Nothing is ever silently dropped.

Two traps, both with I&C analogues:

- **A poll landing mid-mutation must not clobber the optimistic value.** Each
  issue carries a `pendingUntil` timestamp while a mutation is in flight; the
  merge skips remote fields for those issues. Without this, a 60s poll that
  started before your keystroke lands after it and visibly reverts the change —
  the same class of bug as I&C's resurrect loop.
- **Undo is an inverse mutation, not a local edit.** `⌘Z` sends the previous
  `stateId` / `priority` / `dueDate` back to Linear and can itself fail. The undo
  stack holds the whole prior value, not a diff.

**Comments are not undoable.** `⌘Z` after posting one says so rather than doing
nothing, and does not delete it — deleting a teammate-visible comment is a
different act and the app will not do it behind a familiar shortcut.

## 5. The list — sorting, grouping, scope

### 5.1 Sort

Priority · Due date · Created · Updated · Team, each reversible.

**The priority trap:** Linear's scale is `0 = No priority, 1 = Urgent, 2 = High,
3 = Medium, 4 = Low`. Sorting on the raw integer puts "No priority" *first*, which
is exactly wrong — and "No priority" is the most common value in your workspace by
a wide margin. The sort rank is `1, 2, 3, 4, 0`. Display always uses the API's own
`priorityLabel` rather than a local table, so a Linear rename cannot make the app
lie. (I&C's `LinearGraphQL.swift` comment calls `3` "normal"; Linear's own label
is "Medium". That is the bug this paragraph prevents.)

Issues with no due date sort last under Due date, not first.

### 5.2 Group

None · Priority · Status · Project · Milestone · Team.

Grouping and sorting compose: buckets are ordered by the group's own natural
order, and the sort applies within each bucket.

**Status grouping does not fold same-named states across teams.** Each distinct
workflow state gets its own bucket, keyed by its state id. "To Do" on Core UX and
"Todo" on EPD are different statuses and group separately — which is the honest
reading, since they are genuinely different records that each team configured.
Folding by name was considered and cut: it needed a cross-team ordering rule with
no correct answer, and it would have quietly merged states whose meanings diverge.

Bucket order is deterministic:

1. By state `type`, in Linear's own lifecycle order: `triage`, `backlog`,
   `unstarted`, `started`.
2. Then by `position` within the team.
3. Then by team key, then by name — so two teams' states never tie.

When the same name appears in more than one visible bucket, the header
disambiguates (`To Do · CORE`, `To Do · EPD`); when it is unique, the header is
just the name. With the team filter set to one team, that suffix never appears.

**Milestone grouping** reads `Project › Milestone`, because a milestone name
("QA & Bugs", "Planning", "GA") is meaningless without its project — you have a
"GA" milestone under two different projects already. Issues with no milestone fall
into one trailing bucket.

All of this lives in `Models/Ordering.swift` as `nonisolated static` pure
functions over `[Issue]`, which is what makes it testable without a window — I&C's
rule 6, and the reason its selection arithmetic was never the bug.

### 5.3 Scope, and the Backlog toggle

The default list is **everything assigned to you that is not completed or
canceled**, minus one band: states of type `backlog`, which are hidden by default
and shown with `B` or the View menu. The choice persists.

"Blocked" on Core UX is a `backlog`-type state, so hiding Backlog also hides
Blocked. That is intended (Brandon, 2026-10-20): both are "not what I am doing
now", and one toggle for the pair is simpler than a per-state override.

A **team filter** runs along the top as chips — "All" plus one per team, with
counts — exactly like I&C's source chips: `←`/`→` cycles, `⌘1`…`⌘9` jumps, and
the choice persists. Team is the direct analogue of source here, and with seven
teams and most work in Core UX it is how you get to a one-team view in a
keystroke.

**Type-to-filter** narrows the visible list by identifier, title, project,
milestone, status and label. `⌘F` focuses it explicitly; `Esc` clears. It composes
with the team chip and the Backlog toggle rather than overriding them, and the
footer always reports what is hidden and why.

## 6. UX and the command model

### 6.1 The row

One line at rest, like I&C: priority dot, identifier, title, and a right-aligned
cluster of due date, status pill, and project. The selected row expands to show
the description and recent comments (§6.5) — the same "the row you are looking at
is the one that shows its text" rule, for the same reason.

### 6.2 Keyboard

Every one of these is also a real menu item in the window (§6.3), which is what
makes them discoverable rather than folklore.

| Key | Action |
|---|---|
| `↑` / `↓` | Move selection |
| `⌥↑` / `⌥↓` | Previous / next group |
| `⏎` | Open in Linear |
| `space` | Expand / collapse the detail |
| `S` | Status picker |
| `P` | Priority picker |
| `T` | Due date picker |
| `C` | Comment composer |
| `E` | Complete — set the issue's team's default completed state |
| `H` | Hide until… |
| `⌘Z` | Undo the last change |
| `⌘C` | Copy identifier + title + URL |
| `⌘⇧C` | Copy the git branch name |
| `⌘R` | Refresh |
| `G` | Cycle grouping |
| `O` | Cycle sort |
| `B` | Show / hide Backlog |
| `←` / `→` | Cycle the team chips |
| `⌘1`…`⌘9` | Jump to a team chip |
| type | Filter the visible list |
| `⌘F` | Focus the filter |
| `⌘0` | Open the list in a window |
| `Esc` | Close picker → clear filter → close panel |
| `⌘,` | Settings |
| `⌘Q` | Quit |

`E` deserves its own key rather than living inside the status picker because
completing is the thing you do most and the Reminders/Things idiom is one
keystroke. It resolves to the issue's *own team's* default completed state —
which is why the workflow-state cache (§4.4) is not optional.

**Pickers are keyboard-driven overlays**, not menus: type to filter, `↑`/`↓` to
move, `⏎` to apply, `Esc` to cancel. The priority picker also takes `0`–`4`
directly. The due-date picker parses what you would type — `today`, `tomorrow`,
`fri`, `+3d`, `2026-11-05` — and `delete` clears the date. I&C's `SnoozeMenu` is
the shape to copy.

### 6.3 The real menu bar

The window (`⌘0`) carries a full menu bar, and this is the single largest
Mac-arsed difference between a good menu bar app and a web app in a popover:

- **Lineado** — About, Settings `⌘,`, Check for Updates, Quit
- **File** — Open in Linear `⏎`, Copy Link `⌘C`, Copy Branch Name `⌘⇧C`
- **Edit** — Undo `⌘Z`, Find `⌘F`
- **View** — Group by ▸, Sort by ▸, Show Backlog `B`, Team ▸, Refresh `⌘R`
- **Task** — Complete `E`, Status ▸, Priority ▸, Due Date ▸, Comment… `C`, Hide Until ▸
- **Window**, **Help** — standard

The Task menu's submenus are populated live from the selected issue's team, so
the status submenu shows that team's real workflow states. A context menu on a
row mirrors Task.

### 6.4 Drag, drop, and the pasteboard

Dragging a row out of Lineado puts three representations on the pasteboard, so
dropping it somewhere useful just works:

- `public.url` — the `linear.app` issue URL
- `public.utf8-plain-text` — `CORE-1234 Draft the launch announcement… — https://…`
- a rich-text representation with the identifier as the link text

Drop that on Things, Notes, a Slack message, a browser tab bar, or a Markdown
file and you get the right thing. `⌘C` puts the identical set on the general
pasteboard. This is the "I wonder if that works" test and it costs almost nothing.

No drop target in v1 — nothing sensible can be dropped *onto* an issue list that
does not amount to creating issues, which §2 rules out.

### 6.5 Detail and comments

`space` expands the selected row into the issue's description and its last 20
comments, rendered as Markdown, newest last. A composer sits under them; `⌘⏎`
posts, `Esc` cancels with a confirm if the draft is non-empty.

The reason to show the thread rather than a bare composer: nearly every comment
you write from a list is a *reply*. A fire-and-forget box would send you to Linear
to read what you are answering, which is the trip the app exists to prevent.

Detail is fetched on expand, not on poll — one extra request for the row you are
actually reading, rather than twenty-odd descriptions and four hundred comments on
every cycle.

### 6.6 State preservation

Persisted: window frame and whether it was open, sort, group, sort direction,
Backlog visibility, team filter, the expanded row's id, scroll position, filter
text (cleared on relaunch), and the panel's global hotkey. Not persisted: picker
state, drafts beyond the session, transient errors.

### 6.7 Accessibility and appearance

The list is a real `List` with per-row accessibility labels that read the way you
would say it — "CORE-1234, Draft the launch announcement, high priority, due Friday, In
Progress, Core UX". Full keyboard navigation is the primary interface anyway, so
VoiceOver mostly follows for free. Light, dark and increased-contrast appearances;
Reduce Motion disables the row expand animation.

## 7. Distribution

Identical in shape to I&C, because that pipeline is proven and its traps are
already written down:

- **XcodeGen** from `project.yml`; the `.xcodeproj` is not committed.
- **Developer ID** signing, real (not ad-hoc) even locally, so Keychain ACLs and
  TCC grants survive rebuilds. Team `CV926C8KS8`.
- **Bundle id** `lol.bgreen.lineado`.
- **Sparkle** 2.9.6+ for in-app updates, exactly as I&C wires it.
- **Scripts**, ported: `sparkle-tools.sh`, `sparkle-keys.sh`, `notarize.sh`,
  `release.sh`, `appcast.sh`, `install-local.sh`, `verify-bundle.sh`,
  `check-shell.sh`.
- **CI** on every PR; cheap checks on Linux, build and test on macOS. CI never
  signs for real — only `scripts/notarize.sh --preflight-only` on a Mac can tell
  you a build is notarizable.
- **MIT**, like I&C.
- **Homebrew cask** after the first public release, not before.

### Three Sparkle traps, inherited

These cost I&C real time and are written up in its `CLAUDE.md`. They apply
unchanged:

1. **`INFOPLIST_KEY_SUFeedURL` does nothing.** Xcode only synthesises
   `INFOPLIST_KEY_*` for keys it already knows, and `SUFeedURL` is not one. I&C
   shipped a bundle with no feed URL and nothing warned. Set it in the plist and
   have `verify-bundle.sh` assert it.
2. **Xcode leaves Sparkle's nested helpers ad-hoc signed**, which fails
   notarization and which no build failure reveals.
3. **An unsigned appcast entry looks exactly like a working one** until an update
   silently refuses to install.

And one decision that must be made **before the first release**, because changing
it later strands every existing install: **the appcast feed URL**. Decide it in
Phase 0, bake it into the plist, and assert it in `verify-bundle.sh`.

## 8. Milestones

**Phase 0 — Skeleton.** `project.yml`, XcodeGen, a `MenuBarExtra` that opens an
empty panel, Settings with an API-key field writing to the Keychain, Sparkle wired
with its feed URL decided, `verify-bundle.sh` asserting the plist keys. Builds,
signs, installs.

**Phase 1 — The list, read-only.** `LinearClient`, the assigned-issues query, the
workflow-states query, `Issue` + a pure mapper with tests, a flat list in the
panel, the cold-start cache, 60s polling with refresh-on-open, and honest
empty/loading/error states. **Verify the three §4.5 unknowns against the live API
here** — that is what this phase is for.

**Phase 2 — Order.** `Ordering.swift` and its tests: priority rank, cross-team
status ordering, `Project › Milestone` headers, due-date nulls. Then the Backlog
toggle, team chips, type-to-filter, and persistence of all of it.

**Phase 3 — Actions.** Status, priority and due-date pickers; `E` to complete;
`H` to hide locally. Optimistic apply, rollback, the `pendingUntil` guard, and the
undo stack. Every action as a menu item and in the context menu.

**Phase 4 — Detail and comments.** Expand to description plus the last 20
comments, Markdown rendered, inline composer, `⌘⏎` to post.

**Phase 5 — Mac polish.** The `⌘0` window and its full menu bar, state
preservation, drag-out and `⌘C` with multiple representations, the accessibility
pass, appearances, Reduce Motion, and the global hotkey via `KeyboardShortcuts`.

**Phase 6 — Ship.** Notarize, appcast, first tagged release, README, and the
Homebrew cask.

v2, explicitly out of scope above: multi-select and batch actions, App Intents /
Shortcuts, a second Linear workspace, sub-issue trees, and cycle awareness.

## 9. Risks and open questions

- **Query complexity, not request count, is the real Linear limit.** Phase 1 must
  measure it rather than assume the §4.5 query fits. The fallback is moving
  `labels` out of the list query.
- **One API key is one workspace.** v1 is single-workspace; a personal Linear
  account alongside the Buffer one would need a second credential and a source
  concept, which is most of the complexity §2 was cutting.
- **Pagination.** Over 100 open assigned issues the query pages; page to
  completion, because a silently truncated task list is worse than a slow one.
- **Sub-issues** appear as ordinary rows with a parent chip, not a tree. If much
  of your work is sub-issues this will feel flat, and the fix is indentation
  within a group rather than a real outline.
- **`E` needs the workflow-state cache to be warm.** If the states query fails at
  launch, `E` must say so rather than quietly doing nothing.
