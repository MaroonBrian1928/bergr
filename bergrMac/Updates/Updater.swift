import Observation
import MacKit

/// Stub (chunk F wires the menu command and the settings switch): Sparkle's standard updater.
/// `SUFeedURL` and `SUPublicEDKey` come from `Config/Mac-Info.plist`; while the key is empty
/// Sparkle will refuse updates, so nothing is installed by accident.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController

    private init() {
        // Not started: no checks until chunk F turns them on (`startingUpdater: true`).
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// "Check for Updates…"
    func checkForUpdates() { controller.checkForUpdates(nil) }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
}
