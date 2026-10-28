import Foundation
import Testing
@testable import DACBar
import DACDeviceKit

/// The fixtures stand in for hardware, so they have to keep satisfying the
/// same driver contract a real dongle does. Without this, a descriptor change
/// breaks the canvas — silently, and only for whoever next opens it — instead
/// of breaking the build.
@Suite("Hardware-free preview fixtures")
@MainActor
struct PreviewFixtureTests {

    @Test("Every fixture is a complete read the model can reach ready on")
    func fixturesSatisfyTheDriverContract() async throws {
        for fixture in [PreviewDevices.shanlingUA1II, PreviewDevices.tonfa, PreviewDevices.secondModel] {
            let driver = try PreviewDriver(fixture: fixture)
            try driver.descriptor.validate(try await driver.read())

            let model = DeviceModel.preview(fixtures: [fixture])
            for _ in 0..<100 where model.phase != .ready {
                await Task.yield()
            }
            #expect(model.phase == .ready)
            #expect(model.settings.count == fixture.settings.count)
        }
    }
}
