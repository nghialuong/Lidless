import AppKit
import Foundation
import ServiceManagement

/// Manages the privileged helper: registration via SMAppService and XPC calls.
/// All completion handlers are delivered on the main queue.
final class HelperManager {
    private var connection: NSXPCConnection?

    /// Helper label / Mach service name, derived from this app's bundle id so the
    /// `.dev` build talks to its own daemon and never the Release one.
    private var helperLabel: String {
        LidlessHelper.label(appBundleID: Bundle.main.bundleIdentifier ?? "com.nghialuong.lidless")
    }

    /// The generated LaunchDaemon plist embedded at `Contents/Library/LaunchDaemons`.
    private var plistName: String { "\(helperLabel).plist" }

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
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
        // Fallback: the SMAppService call silently no-ops for LSUIElement apps
        // or when System Settings is already running in the background, so also
        // open the Login Items pane by URL, which brings Settings to the front.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: XPC

    private func connect() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
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
