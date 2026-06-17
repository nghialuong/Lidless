import Foundation
import ServiceManagement

/// Manages the privileged helper: registration via SMAppService and XPC calls.
/// All completion handlers are delivered on the main queue.
final class HelperManager {
    static let plistName = "com.nghialuong.lidless.helper.plist"

    private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: Self.plistName)
    }

    // MARK: Registration

    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Register the daemon. Throws if registration fails outright. After this,
    /// `status` may be `.requiresApproval` until the user approves in Settings.
    func register() throws { try service.register() }

    func unregister() throws { try service.unregister() }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: XPC

    private func connect() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(machServiceName: lidlessHelperMachLabel, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: LidlessHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in self?.connection = nil }
        conn.interruptionHandler = { }
        conn.resume()
        connection = conn
        return conn
    }

    private func remote(_ onError: @escaping (String) -> Void) -> LidlessHelperProtocol? {
        let proxy = connect().remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { onError(error.localizedDescription) }
        }
        return proxy as? LidlessHelperProtocol
    }

    func setKeepAwake(_ enabled: Bool, completion: @escaping (Bool, String?) -> Void) {
        guard let r = remote({ completion(false, $0) }) else {
            completion(false, "No helper connection")
            return
        }
        r.setKeepAwake(enabled) { ok, err in
            DispatchQueue.main.async { completion(ok, err) }
        }
    }

    func getState(completion: @escaping (Bool) -> Void) {
        guard let r = remote({ _ in completion(false) }) else {
            completion(false)
            return
        }
        r.getState { value in
            DispatchQueue.main.async { completion(value) }
        }
    }

    func heartbeat() {
        remote({ _ in })?.heartbeat { _ in }
    }
}
