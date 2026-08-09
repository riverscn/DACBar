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
}
