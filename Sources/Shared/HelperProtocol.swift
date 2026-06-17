import Foundation

/// Mach service name shared by the app (client) and the privileged helper (server).
public let lidlessHelperMachLabel = "com.nghialuong.lidless.helper"

/// XPC interface implemented by the root helper and called by the app.
///
/// The helper runs as root (installed via `SMAppService`), so it can flip the
/// `SleepDisabled` flag without an admin prompt. A heartbeat watchdog inside the
/// helper auto-restores normal sleep if the app stops checking in — so the Mac
/// can never get stuck awake if the app crashes or is force-quit.
@objc public protocol LidlessHelperProtocol {
    /// Enable/disable lid-close sleep prevention. reply: (success, errorMessage?).
    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Read the current SleepDisabled flag. reply: (enabled).
    func getState(withReply reply: @escaping (Bool) -> Void)

    /// Heartbeat from the app; resets the watchdog timer.
    func heartbeat(withReply reply: @escaping (Bool) -> Void)

    /// Helper version string, for a connection sanity check.
    func version(withReply reply: @escaping (String) -> Void)
}
