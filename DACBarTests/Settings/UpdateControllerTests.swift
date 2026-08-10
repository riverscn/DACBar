import Foundation
import Testing
@testable import DACBar

@Suite("Sparkle update configuration")
struct UpdateControllerTests {
    @Test("The app String Catalog is embedded and resolves a supported locale")
    func appLocalization() {
        let value = AppL10n.text("action.quit", defaultValue: "Quit")
        #expect(["Quit", "退出"].contains(value))
    }

    @Test("A test bundle without a signed HTTPS feed does not start Sparkle")
    func unsignedBundleIsDisabled() {
        #expect(!UpdateController.hasValidConfiguration(.main))
    }

    @Test("A signed HTTPS feed enables Sparkle")
    func signedHTTPSFeedIsEnabled() {
        #expect(UpdateController.hasValidConfiguration(
            feed: "https://example.com/releases/appcast.xml",
            publicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            requiresSignedFeed: true))
    }

    @Test("A signed feed requires an HTTPS host, a key, and feed signatures")
    func incompleteConfigurationIsDisabled() {
        let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        #expect(!UpdateController.hasValidConfiguration(
            feed: "http://example.com/appcast.xml",
            publicKey: key,
            requiresSignedFeed: true))
        #expect(!UpdateController.hasValidConfiguration(
            feed: "https:///appcast.xml",
            publicKey: key,
            requiresSignedFeed: true))
        #expect(!UpdateController.hasValidConfiguration(
            feed: "https://example.com/appcast.xml",
            publicKey: key,
            requiresSignedFeed: false))
    }

    @MainActor
    @Test("Login-item state follows enabled and approval transitions")
    func loginItemTransitions() {
        let fake = LoginItemPlatformFake()
        let controller = LaunchAtLoginController(platform: fake.platform())
        #expect(controller.state == .disabled)
        #expect(!controller.isEnabled)

        controller.setEnabled(true)
        #expect(controller.state == .enabled)
        #expect(controller.isEnabled)
        #expect(fake.registerCount == 1)

        fake.state = .requiresApproval
        controller.refresh()
        #expect(controller.state == .requiresApproval)
        #expect(controller.isEnabled)

        controller.setEnabled(false)
        #expect(controller.state == .disabled)
        #expect(fake.unregisterCount == 1)
    }

    @MainActor
    @Test("Login-item errors refresh state and settings actions are routed")
    func loginItemErrorsAndSettingsAction() {
        let fake = LoginItemPlatformFake()
        fake.registrationError = PlatformTestError.expected
        let controller = LaunchAtLoginController(platform: fake.platform())

        controller.setEnabled(true)
        #expect(controller.state == .disabled)
        #expect(controller.errorMessage == "Expected platform failure")

        controller.openSystemSettings()
        #expect(fake.openSettingsCount == 1)
    }

    @MainActor
    @Test("Updater observations publish KVO state transitions")
    func updaterObservations() {
        let fake = UpdatePlatformFake()
        fake.canCheck = false
        fake.automaticChecks = true
        fake.automaticDownloads = true
        let controller = UpdateController(platform: fake.platform())

        #expect(controller.isConfigured)
        #expect(!controller.canCheckForUpdates)
        #expect(controller.automaticallyChecksForUpdates)
        #expect(controller.automaticallyDownloadsUpdates)

        fake.emitCanCheck(true)
        fake.emitAutomaticDownloads(false)
        #expect(controller.canCheckForUpdates)
        #expect(!controller.automaticallyDownloadsUpdates)

        fake.automaticDownloads = true
        fake.emitAutomaticChecks(false)
        #expect(!controller.automaticallyChecksForUpdates)
        #expect(!controller.automaticallyDownloadsUpdates)
    }

    @MainActor
    @Test("Updater check and preference actions use the injected adapter")
    func updaterActions() {
        let fake = UpdatePlatformFake()
        let controller = UpdateController(platform: fake.platform())

        controller.check()
        controller.setAutomaticallyChecksForUpdates(true)
        controller.setAutomaticallyDownloadsUpdates(true)

        #expect(fake.checkCount == 1)
        #expect(fake.automaticChecks)
        #expect(fake.automaticDownloads)
        #expect(controller.automaticallyChecksForUpdates)
        #expect(controller.automaticallyDownloadsUpdates)
    }
}

private enum PlatformTestError: LocalizedError {
    case expected

    var errorDescription: String? { "Expected platform failure" }
}

@MainActor
private final class LoginItemPlatformFake {
    var state: LaunchAtLoginController.State = .disabled
    var registrationError: (any Error)?
    var unregistrationError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    func platform() -> LaunchAtLoginPlatform {
        LaunchAtLoginPlatform(
            state: { [weak self] in self?.state ?? .unavailable },
            register: { [weak self] in
                guard let self else { return }
                self.registerCount += 1
                if let registrationError = self.registrationError {
                    throw registrationError
                }
                self.state = .enabled
            },
            unregister: { [weak self] in
                guard let self else { return }
                self.unregisterCount += 1
                if let unregistrationError = self.unregistrationError {
                    throw unregistrationError
                }
                self.state = .disabled
            },
            openSystemSettings: { [weak self] in
                self?.openSettingsCount += 1
            })
    }
}

@MainActor
private final class UpdatePlatformFake {
    final class ObservationToken: NSObject {}

    var canCheck = false
    var automaticChecks = false
    var automaticDownloads = false
    private(set) var checkCount = 0
    private var canCheckDelivery: (@MainActor @Sendable (Bool) -> Void)?
    private var automaticChecksDelivery: (@MainActor @Sendable (Bool) -> Void)?
    private var automaticDownloadsDelivery: (@MainActor @Sendable (Bool) -> Void)?

    func platform() -> UpdatePlatform {
        UpdatePlatform(
            canCheckForUpdates: { [weak self] in self?.canCheck ?? false },
            automaticallyChecksForUpdates: {
                [weak self] in self?.automaticChecks ?? false
            },
            automaticallyDownloadsUpdates: {
                [weak self] in self?.automaticDownloads ?? false
            },
            checkForUpdates: { [weak self] in self?.checkCount += 1 },
            setAutomaticallyChecksForUpdates: {
                [weak self] in self?.automaticChecks = $0
            },
            setAutomaticallyDownloadsUpdates: {
                [weak self] in self?.automaticDownloads = $0
            },
            observeCanCheckForUpdates: { [weak self] delivery in
                self?.canCheckDelivery = delivery
                return ObservationToken()
            },
            observeAutomaticallyChecksForUpdates: { [weak self] delivery in
                self?.automaticChecksDelivery = delivery
                return ObservationToken()
            },
            observeAutomaticallyDownloadsUpdates: { [weak self] delivery in
                self?.automaticDownloadsDelivery = delivery
                return ObservationToken()
            })
    }

    func emitCanCheck(_ value: Bool) {
        canCheck = value
        canCheckDelivery?(value)
    }

    func emitAutomaticChecks(_ value: Bool) {
        automaticChecks = value
        automaticChecksDelivery?(value)
    }

    func emitAutomaticDownloads(_ value: Bool) {
        automaticDownloads = value
        automaticDownloadsDelivery?(value)
    }
}
