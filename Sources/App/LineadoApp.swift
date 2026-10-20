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
            PanelToggler.toggle()
        }
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

/// The menu bar icon.
///
/// A count when there is work, a plain glyph when there is not, and the count
/// tinted when something is overdue — so the icon answers "is anything late?"
/// without opening the panel.
struct MenuBarLabel: View {
    let count: Int
    let overdue: Int

    var body: some View {
        if count == 0 {
            Image(systemName: "checkmark.circle")
        } else if overdue > 0 {
            Image(systemName: "exclamationmark.circle.fill")
            Text("\(count)")
        } else {
            Image(systemName: "circle.dotted")
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
