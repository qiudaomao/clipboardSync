import Sparkle

/// Thin wrapper around Sparkle's standard updater so `AppController` doesn't need to know
/// about `SPUStandardUpdaterController` lifetime/delegate details directly.
final class UpdateController {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
