import AppKit
import Foundation
import Sparkle
import os.log

private let log = Logger(subsystem: "AlbumArtWallpaper", category: "updates")

/// Sparkle, wired for a menu bar app. Sparkle checks the appcast the Release
/// workflow publishes (on launch, then daily), verifies the DMG's EdDSA and
/// code signatures, installs, and relaunches. Scheduled checks that find an
/// update don't pop an alert over whatever the user is doing: Sparkle's
/// "gentle reminders" hand the finding to us, and we publish `availableVersion`
/// so the menu grows an "Update Available" item. Picking that item brings
/// Sparkle's own dialog in focus.
///
/// Only runs for bundled builds. A bare `swift run` binary has no Info.plist,
/// so no feed URL or public key, and Sparkle would put up a misconfiguration
/// alert; development builds never phone home.
@MainActor
final class Updater: NSObject {
    /// The version a scheduled check found, while it's waiting for attention.
    private(set) var availableVersion: String? {
        didSet { onAvailableVersionChanged?() }
    }

    /// Called whenever `availableVersion` changes, so the menu can refresh.
    var onAvailableVersionChanged: (() -> Void)?

    /// True once Sparkle is running, so the menu can offer "Check for Updates".
    var isActive: Bool { controller != nil }

    private let feedURL: String?
    private var controller: SPUStandardUpdaterController?

    init(feedURL: String? = Bundle.main.infoDictionary?["SUFeedURL"] as? String) {
        self.feedURL = feedURL
    }

    func start() {
        guard controller == nil else { return }
        guard feedURL != nil else {
            log.info("no SUFeedURL in the bundle; updates disabled")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.startUpdater()
    }

    /// Check now and show Sparkle's dialog, whatever the outcome. This is also
    /// how a gently-reminded update is brought in focus.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    // MARK: - Badge state

    func noteScheduledUpdate(version: String) {
        availableVersion = version
    }

    func noteUpdateHandled() {
        availableVersion = nil
    }
}

extension Updater: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle offers to show a scheduled update in "immediate focus" only
    /// right after launch or when the system has been idle, when a dialog
    /// won't interrupt anything. Otherwise we take over and badge instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        log.info("scheduled check found \(update.displayVersionString); sparkle shows it: \(handleShowingUpdate)")
        noteScheduledUpdate(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        noteUpdateHandled()
    }

    func standardUserDriverWillFinishUpdateSession() {
        noteUpdateHandled()
    }
}
