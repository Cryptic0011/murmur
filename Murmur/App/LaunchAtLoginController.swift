import Foundation
import ServiceManagement

enum LaunchAtLoginController {
    /// On, including a registration still waiting for approval in System Settings.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Registered, but macOS needs the user to allow Murmur in Login Items first.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !isEnabled {
                try SMAppService.mainApp.register()
            }
        } else if isEnabled {
            // A pending (requiresApproval) registration is withdrawn too.
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
