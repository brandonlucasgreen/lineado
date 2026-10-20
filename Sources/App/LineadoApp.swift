import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct LineadoApp: App {
    @State private var app = AppState()
    // App scope, like Sparkle's own SwiftUI guidance: the updater must outlive
    // any one window, and a menu bar app has no AppDelegate to hang it off.
    @State private var updates = UpdateController()

    init() {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) {
            PanelDiagnostic.record(
                "hotkey fired; modifiers still down = \(NSEvent.modifierFlags.rawValue)")
            PanelToggler.toggle()
        }

        // Temporary probe. NOT a `.task` on a view: the MenuBarExtra label
        // re-renders whenever the issue count changes, which cancels any task
        // attached to it — that is why the first attempt at this never fired.

    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(app)
                .environment(updates)
        } label: {
            MenuBarLabel(count: app.orderedIssues.count,
                         overdue: app.overdueCount)
                // The label is the one view that exists for the app's whole
                // life, so it owns the poll loop. `MenuBarExtra(.window)`
                // builds its *content* lazily — only on the first click — so a
                // loop started in `PanelView` would never run while the panel
                // was closed, and the count beside this glyph would be frozen
                // at whatever the last open left behind.
                .task { app.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Lineado", id: "main") {
            MainWindowView()
                .environment(app)
                .environment(updates)
                // LSUIElement apps have no Dock icon or ⌘Tab entry — while the
                // window is open, become a regular app so it stays reachable,
                // and revert when it closes.
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 720, height: 640)
        .commands { LineadoCommands(app: app, updates: updates) }

        Settings {
            SettingsView()
                .environment(app)
                .environment(updates)
        }
    }
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
}

/// The menu bar icon: a pointing hand, 👉 as a silhouette.
///
/// Chosen by Brandon (2026-10-20) because it ties thematically to Inbox &
/// Chill's peace hand — the two apps read as siblings in one menu bar — and
/// because pointing forward is what Linear is for.
///
/// `hand.point.right` is an SF Symbol rather than a bundled PNG, which means
/// it is already a template image: macOS tints it for the light or dark menu
/// bar, it stays crisp at any scale factor, and it needs no asset catalogue.
///
/// **Solid when something is waiting, hollow only at zero** — exactly the read
/// Inbox & Chill's glyphs carry, and the reason the two apps look like a pair.
///
/// An earlier version filled the hand only when something was *overdue*, which
/// left it hollow in the normal case of "you have 53 tasks, none late" — the
/// opposite of what the glyph should say. Overdue is not the question the icon
/// answers; "is there anything?" is.
struct MenuBarLabel: View {
    let count: Int
    let overdue: Int

    var body: some View {
        if count == 0 {
            Image(systemName: "hand.point.right")
                .accessibilityLabel("Lineado: nothing assigned")
        } else {
            Image(systemName: "hand.point.right.fill")
                .accessibilityLabel(
                    overdue > 0
                        ? "Lineado: \(count) tasks, \(overdue) overdue"
                        : "Lineado: \(count) tasks")
            Text("\(count)")
        }
    }
}

extension AppState {
    /// Visible issues whose due date has passed. Drives the menu bar glyph.
    var overdueCount: Int {
        let today = CalendarDate.today()
        return orderedIssues.filter { issue in
            guard let due = issue.dueDate else { return false }
            return due < today
        }.count
    }
}
