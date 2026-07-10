import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater so `AppController` doesn't need to know
/// about `SPUStandardUpdaterController` lifetime/delegate details directly. Also picks which
/// update feed to use: GitHub when reachable, otherwise the self-hosted mirror published by
/// push.sh, then a jsDelivr mirror as a last resort, for networks where GitHub is blocked.
/// Each feed's enclosure URLs point at the host that serves the feed itself, so whichever
/// source is reachable can also serve the download.
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private static let feedCandidates = [
        "https://raw.githubusercontent.com/qiudaomao/clipboardSyncRelease/main/appcast.xml",
        "https://clipboardsync.fuzhuo.me/downloads/appcast.xml",
        "https://cdn.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/appcast-mirror.xml"
    ]

    private var controller: SPUStandardUpdaterController!
    private let resolvedFeedLock = NSLock()
    private var resolvedFeed: String?

    override init() {
        super.init()
        resolveFeed()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        resolvedFeedLock.lock()
        defer { resolvedFeedLock.unlock() }
        return resolvedFeed ?? Self.feedCandidates[0]
    }

    /// Probes the candidates in order off the main thread and remembers the first reachable
    /// one. Runs once per launch; until it finishes, checks use the primary feed (a check that
    /// races the probe and fails just retries on the next cycle with the resolved feed).
    private func resolveFeed() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            let session = URLSession(configuration: configuration)
            for candidate in Self.feedCandidates {
                guard let url = URL(string: candidate) else {
                    continue
                }
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                let semaphore = DispatchSemaphore(value: 0)
                var reachable = false
                session.dataTask(with: request) { _, response, _ in
                    reachable = (response as? HTTPURLResponse)?.statusCode == 200
                    semaphore.signal()
                }.resume()
                semaphore.wait()
                if reachable {
                    guard let self else {
                        return
                    }
                    self.resolvedFeedLock.lock()
                    self.resolvedFeed = candidate
                    self.resolvedFeedLock.unlock()
                    return
                }
            }
        }
    }
}
