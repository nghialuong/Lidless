import Foundation

/// The `lidless` command-line tool's contract with the app (pure, unit-testable).
///
/// The tool exists so a script or a coding agent can turn keep-awake off without
/// a human at the menu bar — "the job's done, let the Mac sleep again". It talks
/// to the app rather than the helper: the helper only accepts the app, and
/// turning off must go through the app's own switch anyway, or auto mode's armed
/// intent survives and turns keep-awake straight back on at the next tick.
public enum LidlessCLI {
    public enum Command: Equatable {
        case status
        case off
        case help
    }

    /// `lidless` alone reports status, so the safe thing happens by default.
    /// Anything unrecognised is nil rather than a guess.
    public static func parse(_ arguments: [String]) -> Command? {
        switch arguments {
        case []:                          return .status
        case ["status"]:                  return .status
        case ["off"]:                     return .off
        case ["help"], ["-h"], ["--help"]: return .help
        default:                          return nil
        }
    }

    /// Distributed notification the tool posts to ask the app to turn off.
    ///
    /// Distributed notifications carry no sender identity, so any process on the
    /// Mac can post this. That is why the channel only ever turns keep-awake
    /// *off*: the worst a stranger can do with it is let the Mac sleep. Turning
    /// it on stays behind the menu bar and the helper's code signing check.
    ///
    /// Derived from the app's bundle id so the `.dev` build and the released app
    /// each hear only their own tool.
    public static func stopNotificationName(appBundleID: String) -> String {
        "\(appBundleID).cli.stop"
    }

    /// The app's reply to one stop request: posted once the switch is off,
    /// auto mode is disarmed and the flag reads back 0, or once it gives up.
    public static func stoppedNotificationName(appBundleID: String) -> String {
        "\(appBundleID).cli.stopped"
    }

    public enum UserInfoKey {
        public static let requestID = "requestID"
        public static let ok = "ok"
        public static let message = "message"
    }

    /// How long the app keeps trying to confirm before replying with a failure.
    /// Long enough for the admin prompt it falls back to without the helper.
    public static let appConfirmTimeout: TimeInterval = 25
    /// How long the tool waits for that reply. Longer than the app's, so a slow
    /// failure still arrives as a reason rather than a bare timeout.
    public static let toolTimeout: TimeInterval = 30

    public struct StopAck: Equatable {
        public let ok: Bool
        public let message: String?

        public init(ok: Bool, message: String?) {
            self.ok = ok
            self.message = message
        }

        /// The reply to *this* request, or nil. A reply to another invocation —
        /// two agents running `lidless off` at once — mustn't settle this one.
        public init?(userInfo: [AnyHashable: Any]?, requestID: String) {
            guard let info = userInfo,
                  info[UserInfoKey.requestID] as? String == requestID,
                  let ok = info[UserInfoKey.ok] as? Bool else { return nil }
            self.init(ok: ok, message: info[UserInfoKey.message] as? String)
        }
    }

    public enum OffOutcome: Equatable {
        case done
        case waiting
        case failed(String)
    }

    /// Whether `lidless off` may report success.
    ///
    /// The flag reading 0 is not enough on its own. Auto mode can be armed but
    /// paused (unplugged, low battery), with the flag already 0: reporting off
    /// then, before the app has disarmed, leaves keep-awake to come back on the
    /// moment the charger goes in. So success needs the app's reply to this
    /// request, and the tool re-checks both facts itself rather than taking the
    /// reply's word, since any process can post it.
    public static func offOutcome(ack: StopAck?, flag: Bool?, autoMode: Bool, armed: Bool) -> OffOutcome {
        guard let ack else { return .waiting }
        guard ack.ok else { return .failed(ack.message ?? "Lidless couldn't turn keep-awake off.") }
        guard flag == false else {
            return .failed("Lidless replied, but SleepDisabled is \(flag == true ? "still 1" : "unreadable").")
        }
        guard !(autoMode && armed) else {
            return .failed("Lidless replied, but \"Automatically enable when charging\" is still armed.")
        }
        return .done
    }

    /// Where Settings links the tool. On the user's `PATH` by default on macOS.
    public static let installPath = "/usr/local/bin/lidless"

    /// AppleScript that links the bundled tool into `installPath` with an admin
    /// prompt. The tool path comes from wherever the app happens to live, so it
    /// is passed through `quoted form of` for the shell and escaped for the
    /// AppleScript literal — a quote in a folder name must stay a character.
    public static func installScript(toolPath: String) -> String {
        "do shell script \"/bin/mkdir -p /usr/local/bin && /bin/ln -sf \" & quoted form of "
            + appleScriptLiteral(toolPath)
            + " & \" \(installPath)\" with administrator privileges"
    }

    /// A string as an AppleScript string literal, quotes included.
    public static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
