import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct LineadoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Lineado", id: "main") {
            MainWindowView()
                .environment(delegate.appState)
                .environment(delegate.updates)
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
        .commands { LineadoCommands(app: delegate.appState, updates: delegate.updates) }

        Settings {
            SettingsView()
                .environment(delegate.appState)
                .environment(delegate.updates)
                .environment(delegate.loginItem)
        }
    }
}

/// Owns the model and the menu bar.
///
/// There is no `MenuBarExtra` scene: the status item and its panel are created
/// directly by `MenuBarController`, because SwiftUI offers no way to open a
/// `MenuBarExtra` panel from a global hotkey. See that type for the full
/// measurement behind that decision.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let updates = UpdateController()
    let loginItem = LoginItem()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController(appState: appState, updates: updates)
        controller.install()
        menuBar = controller

        appState.start()

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak controller] in
            controller?.toggle()
        }

    }

    /// **Never terminate because no window is visible.**
    ///
    /// This is a menu bar app: having no window on screen is its normal
    /// resting state, not the end of its life. Without this, dismissing the
    /// panel with `Esc` ordered out the only visible window and AppKit shut
    /// the whole app down — which looked exactly like a crash, and left no
    /// crash report because nothing had crashed.
    ///
    /// Reproduced and then confirmed fixed by driving `close()` from a probe
    /// with no window open and checking the process survived.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The panel is not a window in the Dock-menu sense, so without this the
    /// app would have no response at all to being re-opened.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        menuBar?.open()
        return true
    }
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
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
