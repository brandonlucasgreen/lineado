import AppKit
import Foundation
import Observation
import ServiceManagement

/// "Open at Login", via `SMAppService`.
///
/// The modern replacement for the old login-item helper and for
/// `SMLoginItemSetEnabled`: no helper target, no separate bundle, and the user
/// can see and revoke it in System Settings › General › Login Items.
///
/// The part that needs care is `requiresApproval`. Registration can *succeed*
/// and still not run at login, because macOS parks the item awaiting the
/// user's approval — or because they previously switched it off there. A
/// toggle that just reads "on" in that state is lying, so the state is
/// surfaced explicitly and the UI offers the one action that resolves it.
@MainActor
@Observable
final class LoginItem {
    /// What the UI should show. A single value, so the toggle and its
    /// explanation can never disagree.
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS is waiting on the user in System Settings.
        case requiresApproval
        /// `SMAppService` could not find the app bundle — see `isEligible`.
        case unavailable

        var isOn: Bool {
            switch self {
            case .enabled, .requiresApproval: true
            case .disabled, .unavailable: false
            }
        }
    }

    private(set) var state: State = .disabled
    /// Set when register/unregister throws. Cleared on the next success.
    private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    /// Re-reads the live status.
    ///
    /// Called whenever Settings appears, because the user can change this in
    /// System Settings at any time and the app would otherwise show a stale
    /// toggle until relaunch.
    func refresh() {
        state = Self.state(for: service.status)
    }

    nonisolated static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .disabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            // Surfaced, never swallowed: a login item that silently failed to
            // register is indistinguishable from one that worked until the
            // next restart, which is the worst possible moment to find out.
            errorMessage = (error as NSError).localizedDescription
            log.error("Login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
        refresh()
    }

    /// Opens System Settings at Login Items, for the approval case.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether registering would stick.
    ///
    /// `SMAppService` registers the bundle **at its current path**, so a copy
    /// run from DerivedData registers that path and silently stops working the
    /// moment the build directory is cleaned. Only an installed app is worth
    /// offering this for.
    var isEligible: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications")
    }
}
