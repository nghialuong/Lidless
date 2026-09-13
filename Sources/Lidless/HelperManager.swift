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
        LidlessHelper.label(appBundleID: Bundle.main.bundleIdentifier ?? LidlessIdentity.productionAppBundleID)
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

    /// Rebuild the registration from scratch so launchd picks up the *current*
    /// binary. After an app update the daemon's code signature changes and its
    /// launchd job keeps a stale bundle/requirement reference, so launchd refuses
    /// to start the new binary (EX_CONFIG / "could not find and/or execute
    /// program"). A plain re-`register()` does *not* clear that — only a full
    /// unregister (which boots the old job) followed by a fresh register does.
    ///
    /// `unregister` is asynchronous, so we register from its completion (a
    /// register issued immediately after fails with the unregister still settling).
    /// `completion` is delivered on the main queue with any registration error.
    func reregister(completion: @escaping (Error?) -> Void) {
        let svc = service
        svc.unregister { _ in
            // Give launchd/BTM a moment to drop the old job before re-adding it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do {
                    try svc.register()
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

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

    func setKeepAwake(_ enabled: Bool,
                      deadline: ProcessDeadline,
                      completion: @escaping (Bool, String?) -> Void) {
        // The app-created absolute deadline covers XPC transport and helper
        // admission as well as execution; the helper receives the same clock.
        let remaining = deadline.remaining()
        guard remaining > 0 else {
            completion(false, "The background helper request timed out.")
            return
        }
        callWithTimeout(timeout: remaining,
                        completion: completion) { proxy, done in
            proxy.setKeepAwake(
                enabled,
                deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
            ) { ok, err in
                done(ok, err)
            }
        }
    }

    // No `getState` wrapper: the helper's reply is a plain `Bool`, so a failed
    // `pmset -g` inside the daemon would come back as "off" and there'd be no
    // way to tell. Reading needs no privileges, so `PowerManager` reads the flag
    // directly and can report "unknown". The helper is only used to change it.

    func heartbeat() {
        remote({ _ in })?.heartbeat { _ in }
    }

    /// True if the daemon answers an XPC call, false if it can't be reached
    /// (connection error or no reply within the timeout). Used to detect a
    /// registered-but-unlaunchable helper after an app update.
    func checkReachable(completion: @escaping (Bool) -> Void) {
        callWithTimeout(timeout: 5, completion: { ok, _ in completion(ok) }) { proxy, done in
            proxy.version { _ in done(true, nil) }
        }
    }

    /// Run a single XPC call, guaranteeing `completion` fires exactly once on the
    /// main queue. If the daemon never replies — e.g. it fails to launch after an
    /// update, so neither the reply nor the connection's error handler ever fires
    /// — a timeout reports failure instead of leaving the UI hung and silent.
    private func callWithTimeout(timeout: TimeInterval = 6,
                                 completion: @escaping (Bool, String?) -> Void,
                                 _ body: (LidlessHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) {
        var finished = false
        let finish: (Bool, String?) -> Void = { ok, err in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(ok, err)
            }
        }
        guard let proxy = remote({ finish(false, $0) }) else {
            finish(false, "No helper connection")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(false, "The background helper isn’t responding.")
        }
        body(proxy) { ok, err in finish(ok, err) }
    }
}
