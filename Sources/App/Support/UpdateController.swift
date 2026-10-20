import Foundation
import Observation
import Sparkle

/// In-app updates, behind one type.
///
/// Created at `App` scope, which is what Sparkle's own SwiftUI guidance does:
/// the updater must outlive any one window, and a menu bar app has no
/// AppDelegate to hang it off.
///
/// **Three traps, all silent, all inherited from Inbox & Chill:**
///
/// 1. `INFOPLIST_KEY_SUFeedURL` does nothing — Xcode only synthesises
///    `INFOPLIST_KEY_*` for keys it already knows, and `SUFeedURL` is not one.
///    It is set directly in `project.yml`'s `info.properties` and asserted by
///    `scripts/verify-bundle.sh`.
/// 2. Xcode leaves Sparkle's nested helpers ad-hoc signed, which fails
///    notarization and which no build failure reveals.
/// 3. An unsigned appcast entry looks exactly like a working one, until an
///    update silently refuses to install.
@MainActor
@Observable
final class UpdateController {
    @ObservationIgnored private let updater: SPUStandardUpdaterController

    private(set) var canCheckForUpdates = false

    /// True when the build carries no `SUPublicEDKey` — a local build, which
    /// can never install an update. Settings says so plainly rather than
    /// offering a button that would fail later.
    var isUpdateSigningConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").isEmpty
    }

    var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "(none)"
    }

    init() {
        updater = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = updater.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }
}
