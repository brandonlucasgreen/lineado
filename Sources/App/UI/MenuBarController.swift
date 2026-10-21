import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item and the panel, directly.
///
/// **Why this exists instead of `MenuBarExtra`.** SwiftUI's `MenuBarExtra`
/// gives no API for opening its panel from code, and the usual workaround —
/// finding the `NSStatusBarButton` and calling `performClick` — does not work
/// on this macOS. That was measured, not assumed:
///
/// - The handler fires (ten traced presses, ten firings).
/// - The button is found, and it is the *right* button: of the eleven
///   `NSStatusBarWindow`s the system creates, exactly one is on screen and
///   carries our title; the other ten are empty placeholders parked at y=-39.
/// - That button has `target == nil` and `action == nil`, so `performClick`
///   has nothing to dispatch.
/// - Synthesising a mouse event with `sendEvent` **hangs the app**: a status
///   item's mouse-down enters a modal tracking run loop waiting for the
///   matching mouse-up, so delivering the down synchronously blocks the main
///   thread inside that loop. A sample showed it parked in a nested
///   `CFRunLoopRun`. Posting both events to the queue instead does not hang,
///   and also does not open the panel.
///
/// So the panel is ours: an `NSStatusItem` and an `NSPanel` we create and
/// position. That also makes two things possible that `MenuBarExtra` does not
/// allow at all — dismissing on `Esc` with focus returned to the app you came
/// from, and closing when you click away.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    /// Whoever was frontmost when the panel opened, so Esc can hand the
    /// keyboard straight back to them.
    private var previousApp: NSRunningApplication?
    private let appState: AppState
    private let updates: UpdateController

    init(appState: AppState, updates: UpdateController) {
        self.appState = appState
        self.updates = updates
        super.init()
    }

    // MARK: Setup

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Without this the button only reports left clicks, and a right click
        // would do nothing at all rather than offering the menu.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateButton()
        observeState()
    }

    /// Redraws the icon and count whenever the model changes.
    ///
    /// `withObservationTracking` fires once per change, so it re-arms itself.
    /// This replaces the `.task` that used to hang off the `MenuBarExtra`
    /// label — which was cancelled on every re-render, because the label
    /// displayed the very count it depended on.
    private func observeState() {
        withObservationTracking {
            _ = appState.orderedIssues.count
            _ = appState.overdueCount
            // Read here so flipping the setting redraws at once, not at the
            // next poll.
            _ = appState.preferences.showsMenuBarCount
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateButton()
                self?.observeState()
            }
        }
    }

    /// The glyph's point size, sized against Inbox & Chill's peace hand.
    ///
    /// Measured 2026-10-21 by rasterising both and taking the bounding box of
    /// drawn pixels. The default-size `hand.point.right` drew 13.5 × 10.5pt
    /// against the peace hand's 12.5 × 16pt — about 30% less ink, which is why
    /// it read as small beside its neighbours. A pointing-right hand is wide and
    /// short, so matching the peace hand's *height* would make it 21pt wide.
    /// At 15pt its longest side is 16pt and its drawn area is 16 × 12.5 =
    /// 200 sq pt — the same visual weight as the peace hand, turned sideways.
    static let glyphPointSize: CGFloat = 15

    /// What the status item reads, as a pure function so it can be tested.
    /// Hidden at zero regardless — the hollow hand already says "nothing".
    nonisolated static func title(count: Int, showsCount: Bool) -> String {
        guard showsCount, count > 0 else { return "" }
        return " \(count)"
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let count = appState.orderedIssues.count
        // Solid when something is waiting, hollow only at zero — the read
        // Inbox & Chill's glyphs carry, so the two apps look like a pair.
        // Independent of whether the count is shown: the glyph still answers
        // "is there anything?" when the number is turned off.
        let symbol = count == 0 ? "hand.point.right" : "hand.point.right.fill"
        // The count stays in the accessibility description even when it is
        // hidden from the bar: hiding it is a visual preference, and VoiceOver
        // users should not lose the information because of it.
        let description = count == 0
            ? "Lineado: nothing assigned"
            : (appState.overdueCount > 0
                ? "Lineado: \(count) tasks, \(appState.overdueCount) overdue"
                : "Lineado: \(count) tasks")

        let config = NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true

        let title = Self.title(count: count, showsCount: appState.preferences.showsMenuBarCount)
        button.title = title
        // `.imageLeading` with an empty title still reserves space for text,
        // which leaves the glyph off-centre in a wider-than-needed item.
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }

    // MARK: Opening and closing

    /// Re-entrancy guard.
    ///
    /// Belt to the braces of `showContextMenu` no longer synthesising a click:
    /// anything that re-enters this handler while it is running is a bug, and
    /// a dropped click is a far better symptom than a blown stack.
    private var isHandlingClick = false

    @objc private func statusItemClicked() {
        guard !isHandlingClick else { return }
        isHandlingClick = true
        defer { isHandlingClick = false }

        let isSecondary = NSApp.currentEvent.map { event in
            event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        } ?? false

        if isSecondary { showContextMenu() } else { toggle() }
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        // Captured before we activate, or it would just be us.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)

        // `.nonactivatingPanel` would keep the app in the background, but then
        // the filter field and the comment composer could never take a
        // keystroke. Activating is what makes the panel usable.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        startOutsideClickMonitor()
    }

    /// Hides the panel. `restoringFocus` hands the keyboard back to whatever
    /// app you were in — what `Esc` should do.
    ///
    /// **Reactivates that app explicitly; never `NSApp.hide(nil)`.** Hiding
    /// took the whole app down with the panel, which read as Esc quitting
    /// Lineado — and left no crash report, because nothing crashed. Naming the
    /// app to activate is both narrower and more accurate: the point was never
    /// to hide ourselves, it was to give focus back.
    func close(restoringFocus: Bool = false) {
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        stopOutsideClickMonitor()

        if restoringFocus,
           let previousApp,
           previousApp.bundleIdentifier != Bundle.main.bundleIdentifier,
           !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func makePanel() -> NSPanel {
        // **Borderless, not `.titled`.** A titled panel reserves its title bar
        // height even with `.fullSizeContentView` and a hidden, transparent
        // title bar — which showed up as a band of dead space above the filter
        // field. Removing the style mask removes the reservation structurally,
        // rather than trying to inset around it.
        //
        // The cost is that the window no longer draws its own background,
        // corners or border, so the SwiftUI root does all three. And a
        // borderless window refuses key status by default, which is why
        // `KeyablePanel` overrides `canBecomeKey` — without it the filter
        // field and the comment composer could not take a keystroke.
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        // Follows the active Space rather than yanking you to another one.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let root = PanelView()
            .environment(appState)
            .environment(updates)
            .environment(\.menuBarController, self)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    static let panelSize = CGSize(width: 460, height: 560)

    /// Places the panel under the menu bar icon, nudged inside the screen if
    /// the icon sits near the right edge.
    private func position(_ panel: NSPanel) {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return }

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(
            x: buttonFrame.midX - size.width / 2,
            y: buttonFrame.minY - size.height - 6)

        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrameOrigin(origin)
    }

    // MARK: Click-away

    /// Closes the panel when you click outside it, the way a real menu does.
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: Right-click menu

    /// Pops the menu up directly.
    ///
    /// **Not** by assigning `statusItem.menu` and calling `performClick`. That
    /// is the widely-posted trick and it is infinitely recursive here:
    /// `performClick` synchronously re-invokes the button's action, which
    /// lands back in `statusItemClicked`, where `NSApp.currentEvent` is still
    /// the same right-mouse-up — so it calls this method again, forever, until
    /// the stack is gone. There is no base case.
    ///
    /// `popUp(positioning:at:in:)` needs no click to synthesise and no
    /// temporary mutation of the status item, so neither problem exists.
    private func showContextMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        for (title, action, key) in [
            ("Refresh", #selector(refresh), "r"),
            ("Open in Window", #selector(openWindow), "0"),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Quit Lineado", action: #selector(quit), keyEquivalent: "q")
            .target = self

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func openWindow() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
    }

    @objc private func refresh() { Task { await appState.refresh() } }
    @objc private func openSettings() { SettingsWindow.openFromMenuBar() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// A panel that can take keyboard focus.
///
/// `NSPanel` refuses key status by default when it has no title bar, which
/// would leave the filter field and the comment composer unable to receive a
/// single keystroke.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Environment

private struct MenuBarControllerKey: EnvironmentKey {
    static let defaultValue: MenuBarController? = nil
}

extension EnvironmentValues {
    var menuBarController: MenuBarController? {
        get { self[MenuBarControllerKey.self] }
        set { self[MenuBarControllerKey.self] = newValue }
    }
}
