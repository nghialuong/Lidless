import Foundation
import ServiceManagement

/// Launch-at-login for the app itself, via SMAppService.mainApp (macOS 13+).
/// Separate from the privileged helper daemon.
struct LoginItemManager {
    private var service: SMAppService { .mainApp }

    var isEnabled: Bool { service.status == .enabled }

    /// Toggle launch-at-login. Returns an error message on failure, nil on success.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
