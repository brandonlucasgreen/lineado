# Lineado on iOS and the App Store — Plan

Written 2026-10-20 to consider later. Nothing here is built. `PLAN.md` remains
the design source of truth for the macOS app; this document is the plan for
taking it further.

> *"I would like to then understand what it might take to create this app for
> ios and generally make it ready for the apple app stores. A version of this
> app on iOS, particularly with todo-app-like widgets, could be powerful too."*
> — Brandon, 2026-10-20

---

## 1. The short version

**It is doable, and Lineado is in good shape for it.** Most of the code is
already platform-free, the App Store blockers are known and few, and the one
genuinely hard question — how an iPhone stays fresh without a server — has a
reasonable answer that does not require deciding today.

Four phases, in this order:

1. **Extract a shared `LineadoKit` package** — 1–2 days.
2. **A Mac App Store build** alongside the direct one — 3–5 days, plus review.
3. **An iOS app** — 1–2 weeks.
4. **Widgets**, including a tickable checkbox — 3–5 days.

Phases 1 and 2 are independent of each other. Phase 3 needs phase 1. Phase 4
needs phase 3.

Sold as one **universal purchase**: a single App Store record covering both the
Mac and iOS apps, under the same bundle id family.

## 2. Where the code stands

Measured 2026-10-20 by checking every source file for macOS-only API
(`AppKit`, `NSStatusItem`, `NSPanel`, `NSWorkspace`, `NSPasteboard`, `NSEvent`,
`SMAppService`, `KeyboardShortcuts`, `Sparkle`):

- **~4,000 of ~6,300 lines use none of it.** That is the whole Linear layer
  (`LinearClient`, queries, wire types, `LinearMapper`, `LinearService`), the
  models (`Issue`, `Workspace`), all of `Ordering`, `DateParsing`, the
  `MarkdownBlock` parser, `Preferences`, `Storage`, `Keychain`, and most of
  `AppState`.
- **`KeyMap` is pure apart from its `NSEvent` initialiser.** Split that off and
  the whole keyboard map carries to an iPad with a hardware keyboard.
- **All 95 tests are over pure functions**, so they move with the package
  unchanged.

The macOS-only remainder is the menu bar shell (`MenuBarController`, the
panel), Sparkle, the login item, the global hotkey and the pasteboard — none of
which an iOS app wants anyway.

## 3. Phase 1 — `LineadoKit`

Move the platform-free code into a local Swift package that both apps depend
on. No behaviour changes; the macOS app must build, run and pass every test
exactly as before.

- Declared in `project.yml` (XcodeGen), with its own test target.
- `MarkdownText.swift` splits: the `MarkdownBlock` parser moves, the SwiftUI
  view that renders it stays (or moves later, once iOS needs it).
- `KeyInput.init(_: NSEvent)` stays in the app; `KeyMap` and `KeyBinding` move.
- `AppState` is `@MainActor @Observable` and imports SwiftUI, which is fine on
  iOS — but check it for stray AppKit before moving it.

**Done looks like:** same 95 tests green, the installed app still loads issues.

## 4. Phase 2 — the Mac App Store build

A second target beside the direct (Developer ID + Sparkle) one, not a branch.
Inbox & Chill already does exactly this; its `docs/app-store-plan.md` §1–§2 is
the reference and applies almost verbatim. Lineado has far less to cut: no
licensing, no CLI, no Mail, no Journal.

### Verified blockers

Checked in the code on 2026-10-20, not inferred:

- ~~**There is no app icon.**~~ Resolved 2026-10-21: a silver Fluent 👉 on
  black, built on Inbox & Chill's grid (`docs/brand/`). `verify-bundle.sh` now
  fails a bundle without it. An iOS version needs its own square, unmasked
  1024px render — iOS applies its own corner mask.
- **No `PrivacyInfo.xcprivacy`.** Required for both builds. `UserDefaults` is a
  "required reason" API (reason `CA92.1`); check whether anything reads file
  timestamps too.
- **No `LSApplicationCategoryType` or `ITSAppUsesNonExemptEncryption`** in
  `project.yml`. Inbox & Chill's first upload was rejected for the category.
  Encryption is `NO` — the app only uses the system's HTTPS.
- **Two private-selector strings** — a guideline 2.5.1 risk, and fragile in the
  direct build too, so worth fixing regardless:
  - `NSApp.sendAction(Selector(("showSettingsWindow:")))` in `PanelChrome.swift`
  - `NSApp.sendAction(Selector(("newWindowForTab:")))` in
    `MenuBarController.swift`
- **Sparkle must be compiled out** of the store build (guideline 2.4.5(vii):
  updates come from the store). `UpdateController` becomes a stub behind
  `#if !APP_STORE`, as in Inbox & Chill.

### The sandbox

The store build needs `com.apple.security.app-sandbox` plus
`com.apple.security.network.client` — nothing else. Known to work under it,
from Inbox & Chill's audit: `SMAppService` (Open at Login), the
KeyboardShortcuts global hotkey, the Keychain (container-scoped), pasteboard,
App Intents.

**Unverified:** `NSEvent.addGlobalMonitorForEvents` for mouse-down, which is how
the panel closes when you click away. Test it under the sandbox before relying
on it.

### Review

- **App Review needs a working Linear account.** Provide a demo workspace and a
  personal API key in the review notes. Much easier than Inbox & Chill, which
  needed credentials for five services.
- **A privacy policy URL is mandatory** in App Store Connect. See §8 — it needs
  the same domain that is blocking the Sparkle feed.
- Build the store target into `dist/app-store/`, never `/Applications`, or it
  replaces the direct build you use (Inbox & Chill learned this).

## 5. Phase 3 — the iOS app

### What is shared, what is new

Everything in `LineadoKit`. The UI is new, because the interaction model is:

- **Swipe actions instead of single-letter keys** — swipe to complete, swipe for
  priority and due date. Context menus on long-press mirror the Mac's.
- **Pickers as sheets or menus** rather than overlays. `DateParsing` still
  powers a typed due date.
- **The filters as segmented controls or a menu**, with the same workspace-
  then-team nesting.
- **iPad with a hardware keyboard gets the full `KeyMap`** for free, which is a
  genuinely good iPad app.

Multiple workspaces, per-workspace failure isolation, the hide-until state and
the optimistic writes all come across unchanged.

### The one real constraint: freshness

**iOS will not let an app poll every 60 seconds.** The Mac app does; an iPhone
app gets:

- a refresh whenever it is opened or brought to the foreground,
- occasional background refreshes via `BGAppRefreshTask`, on the system's
  schedule, not ours,
- widget timeline reloads (§6).

That is enough for a to-do list you open a few times a day. It is not live.

**Truly live updates need a server**: something that receives Linear's webhooks
when an issue changes and sends a silent push to the phone. Lineado has no
server today and does not need one for the Mac. This is the one real fork in
the design, and it can be decided after shipping without it — start with
foreground and background refresh, and add push only if staleness turns out to
matter in use.

Worth verifying before choosing push: who can create Linear webhooks
(likely workspace admins, or an OAuth app's subscriptions), and what that means
for a user who is not an admin of their workspace.

## 6. Phase 4 — widgets

This is where an iOS version earns its keep.

### Interactive widgets

Since iOS 17, a widget can run an **App Intent** from a button. So the core of
it is a **tickable checkbox on the home screen**: complete a Linear task without
opening anything, exactly like Reminders or Things. The same intents can set a
due date to today or bump priority.

### Sizes

- **Small** — the count, plus the next task.
- **Medium** — three or four tasks, each tickable.
- **Large** — a grouped list (by status or due date).
- **Lock Screen** — the count, or the next due task.
- **StandBy** — falls out of the small and medium layouts.
- **Control Center** (iOS 18) — a control that opens Lineado to the list.

### What it needs

- **An App Group**, so the app and the widget extension share one container.
  The issue cache (`IssueCache`, `Storage`) moves into it.
- **A shared Keychain access group**, so the widget's intents can hold the API
  keys and perform writes themselves.
- The optimistic-write logic in `AppState+Mutations` reused by the intents, so
  a tick in a widget behaves like a tick in the app.

### The catch

**iOS rations widget refreshes** — Apple's guidance is roughly 40–70 reloads a
day for a widget that is viewed often. A change made in Linear itself can take
a while to appear. A change made in the app or the widget appears immediately,
because the app reloads widget timelines after every write.

### Free extras

- **The same widgets on the Mac desktop and in Notification Center**, from one
  widget extension, at little extra cost.
- **Siri and Shortcuts**: the App Intents that power the widgets also make
  "complete my Linear task" work in Shortcuts, Siri and Spotlight. That was a v2
  item in `PLAN.md`.

## 7. Order and effort

- **Phase 1, `LineadoKit`** — 1–2 days. Unblocks phase 3.
- **Phase 2, Mac App Store build** — 3–5 days, plus review cycles. Independent
  of phase 1.
- **Phase 3, iOS app** — 1–2 weeks.
- **Phase 4, widgets with interactive complete** — 3–5 days.

The estimates assume the decisions in §8 are made before each phase starts.
For calibration: `PLAN.md` once predicted multi-workspace support would cost
"most of the complexity" the design had cut; it took about 450 lines, because
the seams were already in place. Treat these numbers the same way — the
architecture is friendlier to this than a naive estimate assumes.

## 8. Decisions only Brandon can make

- **Pricing.** Free, paid upfront, or in-app purchase. Universal purchase means
  one price covers both platforms.
- **The domain.** App Store Connect requires a privacy policy URL, and the
  Sparkle feed (`SUFeedURL`, currently the placeholder `UNSET-pending-domain`)
  needs a permanent home. One domain answers both.
- **How strangers connect to Linear.** Pasting a personal API key works but is
  rough for a public app. The alternative is registering **one** Linear OAuth
  app and offering "Sign in with Linear". Inbox & Chill dropped OAuth because
  every *user* had to register their own app — that objection does not apply
  to an app the developer publishes.
- **Whether to run a server** for live push (§5). Can wait until after launch.

## 9. Not yet known

- Whether the global mouse monitor works under the Mac App Store sandbox.
- Who can create Linear webhooks, if push is ever wanted.
- Whether Linear's OAuth apps need workspace-admin approval to install, which
  would affect "Sign in with Linear" for users in locked-down workspaces.
- The query-complexity cost of the 100-node assigned-issues query, now run once
  per workspace — still unmeasured on the Mac, and more pressing on iOS where
  each background refresh is precious.
