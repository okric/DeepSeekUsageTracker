import AppKit
import Sparkle

/// Wraps Sparkle's standard updater so the rest of the app does not import it.
///
/// The feed URL and EdDSA public key live in `Resources/Info.plist`
/// (`SUFeedURL`, `SUPublicEDKey`); releases are signed by `Scripts/notarize.sh`.
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }

    /// Sparkle disables manual checks while one is already running.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
