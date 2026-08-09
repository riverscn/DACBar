import AppKit
import Foundation
import Observation
import Sparkle

@Observable
@MainActor
final class UpdateController {
    @ObservationIgnored
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored
    private var canCheckObservation: NSKeyValueObservation?

    var isConfigured: Bool { controller != nil }
    private(set) var canCheckForUpdates = false

    init(bundle: Bundle = .main) {
        guard Self.hasValidConfiguration(bundle) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let canCheckForUpdates = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheckForUpdates
            }
        }
    }

    func check() {
        controller?.checkForUpdates(nil)
    }

    nonisolated static func hasValidConfiguration(_ bundle: Bundle) -> Bool {
        hasValidConfiguration(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            requiresSignedFeed: bundle.object(
                forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true)
    }

    nonisolated static func hasValidConfiguration(
        feed: String?,
        publicKey: String?,
        requiresSignedFeed: Bool
    ) -> Bool {
        guard let feed,
              let feedURL = URL(string: feed),
              feedURL.scheme?.lowercased() == "https",
              let host = feedURL.host, !host.isEmpty,
              let publicKey,
              requiresSignedFeed
        else { return false }
        return Data(base64Encoded: publicKey)?.count == 32
    }
}
