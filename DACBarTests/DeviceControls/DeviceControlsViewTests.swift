import Foundation
import Testing
@testable import DACBar
import DACDeviceKit

@Suite("Capability-driven control groups")
struct DeviceControlsViewTests {

    @Test("Every custom collapsible group has writable independent state")
    func customCollapsibleGroupsPersistIndependently() {
        let first = DACDeviceKit.SettingGroup(
            id: "custom-one", title: "Custom One", isCollapsible: true)
        let second = DACDeviceKit.SettingGroup(
            id: "custom-two", title: "Custom Two", isCollapsible: true)
        let firstPreference = SettingGroupExpansionPreference(group: first)
        let secondPreference = SettingGroupExpansionPreference(group: second)
        let suiteName = "DACBarTests.DeviceControls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStorage = firstPreference.storage(store: defaults)
        let secondStorage = secondPreference.storage(store: defaults)
        #expect(firstStorage.wrappedValue)
        #expect(secondStorage.wrappedValue)

        firstStorage.wrappedValue = false

        #expect(!firstStorage.wrappedValue)
        #expect(secondStorage.wrappedValue)
        #expect(firstPreference.key != secondPreference.key)
    }

    @Test("The display group retains its existing collapsed preference")
    func displayGroupRetainsLegacyPreference() {
        let preference = SettingGroupExpansionPreference(group: .display)

        #expect(preference.key == "showDisplaySection")
        #expect(!preference.defaultValue)
    }
}
