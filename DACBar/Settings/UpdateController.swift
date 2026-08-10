import AppKit
import Foundation
import Observation
import Sparkle

@MainActor
struct UpdatePlatform {
    let canCheckForUpdates: () -> Bool
    let automaticallyChecksForUpdates: () -> Bool
    let automaticallyDownloadsUpdates: () -> Bool
    let checkForUpdates: () -> Void
    let setAutomaticallyChecksForUpdates: (Bool) -> Void
    let setAutomaticallyDownloadsUpdates: (Bool) -> Void
    let observeCanCheckForUpdates:
        (@escaping @MainActor @Sendable (Bool) -> Void) -> AnyObject
    let observeAutomaticallyChecksForUpdates:
        (@escaping @MainActor @Sendable (Bool) -> Void) -> AnyObject
    let observeAutomaticallyDownloadsUpdates:
        (@escaping @MainActor @Sendable (Bool) -> Void) -> AnyObject

    static func live() -> UpdatePlatform {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        let updater = controller.updater
        return UpdatePlatform(
            canCheckForUpdates: { updater.canCheckForUpdates },
            automaticallyChecksForUpdates: { updater.automaticallyChecksForUpdates },
            automaticallyDownloadsUpdates: { updater.automaticallyDownloadsUpdates },
            checkForUpdates: { controller.checkForUpdates(nil) },
            setAutomaticallyChecksForUpdates: {
                updater.automaticallyChecksForUpdates = $0
            },
            setAutomaticallyDownloadsUpdates: {
                updater.automaticallyDownloadsUpdates = $0
            },
            observeCanCheckForUpdates: { delivery in
                updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                    _, change in
                    guard let value = change.newValue else { return }
                    Task { @MainActor in delivery(value) }
                }
            },
            observeAutomaticallyChecksForUpdates: { delivery in
                updater.observe(
                    \.automaticallyChecksForUpdates, options: [.initial, .new]
                ) { _, change in
                    guard let value = change.newValue else { return }
                    Task { @MainActor in delivery(value) }
                }
            },
            observeAutomaticallyDownloadsUpdates: { delivery in
                updater.observe(
                    \.automaticallyDownloadsUpdates, options: [.initial, .new]
                ) { _, change in
                    guard let value = change.newValue else { return }
                    Task { @MainActor in delivery(value) }
                }
            })
    }
}

@Observable
@MainActor
final class UpdateController {
    @ObservationIgnored
    private let platform: UpdatePlatform?
    @ObservationIgnored
    private var canCheckObservation: AnyObject?
    @ObservationIgnored
    private var automaticChecksObservation: AnyObject?
    @ObservationIgnored
    private var automaticDownloadsObservation: AnyObject?

    var isConfigured: Bool { platform != nil }
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false

    convenience init(bundle: Bundle = .main) {
        self.init(platform: Self.hasValidConfiguration(bundle) ? .live() : nil)
    }

    init(platform: UpdatePlatform?) {
        self.platform = platform
        guard let platform else { return }
        canCheckForUpdates = platform.canCheckForUpdates()
        automaticallyChecksForUpdates = platform.automaticallyChecksForUpdates()
        automaticallyDownloadsUpdates = platform.automaticallyDownloadsUpdates()
        canCheckObservation = platform.observeCanCheckForUpdates { [weak self] value in
            self?.canCheckForUpdates = value
        }
        automaticChecksObservation = platform.observeAutomaticallyChecksForUpdates {
            [weak self] value in
            self?.automaticallyChecksForUpdates = value
            if value == false {
                self?.automaticallyDownloadsUpdates = false
            }
        }
        automaticDownloadsObservation = platform.observeAutomaticallyDownloadsUpdates {
            [weak self] value in
            self?.automaticallyDownloadsUpdates = value
        }
    }

    func check() {
        platform?.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let platform else { return }
        platform.setAutomaticallyChecksForUpdates(enabled)
        automaticallyChecksForUpdates = platform.automaticallyChecksForUpdates()
        automaticallyDownloadsUpdates = platform.automaticallyDownloadsUpdates()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let platform else { return }
        platform.setAutomaticallyDownloadsUpdates(enabled)
        automaticallyDownloadsUpdates = platform.automaticallyDownloadsUpdates()
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
