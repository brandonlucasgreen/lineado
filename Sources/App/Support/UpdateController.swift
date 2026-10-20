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

    /// Whether this build could install an update at all.
    ///
    /// Two independent reasons it might not, and Settings has to say which:
    /// no signing key (a local build), or no real feed yet — the feed domain
    /// is deliberately unbought (project.yml), so the URL is a placeholder.
    /// Either way, offering a Check Now button that can only fail is worse
    /// than saying so.
    var isUpdateSigningConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").isEmpty && hasRealFeed
    }

    var hasRealFeed: Bool { feedURL.hasPrefix("https://") }

    var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "(none)"
    }

    /// What Settings shows when updates are not wired up.
    var unavailableReason: String {
        if !hasRealFeed {
            return "Updates aren't set up yet — there's no release feed. Lineado will tell you when there is one."
        }
        return "Builds you make yourself can't verify an update, so automatic updates are off. Released builds carry the signing key."
    }

    init() {
        // `startingUpdater: true` makes Sparkle validate SUFeedURL immediately,
        // and it raises on a value that is not a URL. Ours is deliberately a
        // placeholder until the feed domain exists, so the updater is created
        // but **not started** until there is something real to point it at.
        //
        // Starting it later is supported; raising on launch is not recoverable.
        let feedIsReal = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")
            .hasPrefix("https://")

        updater = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

        guard feedIsReal else {
            canCheckForUpdates = false
            log.info("Sparkle not started: SUFeedURL is a placeholder, no release feed yet")
            return
        }

        do {
            try updater.updater.start()
            canCheckForUpdates = updater.updater.canCheckForUpdates
        } catch {
            // A failure here means no updates, not no app.
            canCheckForUpdates = false
            log.error("Sparkle failed to start: \(String(describing: error))")
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }
}
