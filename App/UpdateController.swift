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
    @ObservationIgnored
    private var automaticChecksObservation: NSKeyValueObservation?
    @ObservationIgnored
    private var automaticDownloadsObservation: NSKeyValueObservation?

    var isConfigured: Bool { controller != nil }
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false

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
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let canCheckForUpdates = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheckForUpdates
            }
        }
        automaticChecksObservation = controller.updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = value
                if value == false {
                    self?.automaticallyDownloadsUpdates = false
                }
            }
        }
        automaticDownloadsObservation = controller.updater.observe(
            \.automaticallyDownloadsUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.automaticallyDownloadsUpdates = value
            }
        }
    }

    func check() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
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
