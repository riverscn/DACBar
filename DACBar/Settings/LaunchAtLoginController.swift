import Observation
import ServiceManagement

@MainActor
struct LaunchAtLoginPlatform {
    let state: () -> LaunchAtLoginController.State
    let register: () throws -> Void
    let unregister: () throws -> Void
    let openSystemSettings: () -> Void

    static let live: LaunchAtLoginPlatform = {
        let service = SMAppService.mainApp
        return LaunchAtLoginPlatform(
            state: {
                switch service.status {
                case .enabled: .enabled
                case .requiresApproval: .requiresApproval
                case .notFound: .unavailable
                case .notRegistered: .disabled
                @unknown default: .unavailable
                }
            },
            register: { try service.register() },
            unregister: { try service.unregister() },
            openSystemSettings: { SMAppService.openSystemSettingsLoginItems() })
    }()
}

@MainActor
@Observable
final class LaunchAtLoginController {
    enum State: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable
    }

    private(set) var state: State = .disabled
    private(set) var errorMessage: String?

    @ObservationIgnored private let platform: LaunchAtLoginPlatform

    init(platform: LaunchAtLoginPlatform = .live) {
        self.platform = platform
        refresh()
    }

    // Keep the toggle on while macOS is waiting for approval. The service is
    // already registered in this state, and turning the toggle off should
    // unregister that pending request.
    var isEnabled: Bool { state == .enabled || state == .requiresApproval }

    func refresh() {
        state = platform.state()
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try platform.register()
            } else {
                try platform.unregister()
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    func openSystemSettings() {
        platform.openSystemSettings()
    }
}
