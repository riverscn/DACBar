import Observation
import ServiceManagement

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

    @ObservationIgnored private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    // Keep the toggle on while macOS is waiting for approval. The service is
    // already registered in this state, and turning the toggle off should
    // unregister that pending request.
    var isEnabled: Bool { state == .enabled || state == .requiresApproval }

    func refresh() {
        state = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        case .notRegistered: .disabled
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
