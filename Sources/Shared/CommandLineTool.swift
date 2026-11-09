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

    /// The one program that places the link, run as `sh -c <program> lidless-install
    /// <mode> <tool> <destination> <owner uid>`. `mode` is `check` (no writes, run
    /// as the user before any password prompt) or `install`.
    ///
    /// It runs as root, so it trusts nothing it didn't check itself:
    /// - The destination may only be absent, this tool's link already, or a link
    ///   left by another copy of Lidless (`*/Lidless.app/Contents/Helpers/lidless`).
    ///   A regular file, a directory, or any other link is refused, never replaced.
    /// - The folder must be a real directory owned by `owner`. When that's root,
    ///   it and every folder above it must be root-owned, writable by nobody
    ///   else, and not links, so no one can swap in a directory or a link
    ///   between the check and the write.
    /// - `ln -sn` without `-f`: it neither follows a link at the destination nor
    ///   overwrites anything that appeared since the check. `rm` without `-r`
    ///   removes a stale link and can't take a directory with it.
    public static let installProgram = """
    set -eu
    mode=$1 src=$2 dst=$3 owner=$4
    dir=${dst%/*}
    fail() { echo "$1" >&2; exit 1; }
    checkdir() {
      if [ ! -d "$1" ] || [ -L "$1" ]; then fail "$1 is not a plain folder."; fi
      [ "$(/usr/bin/stat -f %u "$1")" = "$2" ] || fail "$1 isn't owned by the expected user."
      case "$(/usr/bin/stat -f %Sp "$1")" in
        ?????w????|????????w?) fail "$1 is writable by other users." ;;
      esac
    }
    # Folders above first, so mkdir can't be steered through a link.
    if [ "$owner" = 0 ]; then
      up=${dir%/*}
      while [ -n "$up" ]; do
        if [ -e "$up" ] || [ -L "$up" ]; then checkdir "$up" 0; fi
        up=${up%/*}
      done
    fi
    if [ "$mode" = install ]; then /bin/mkdir -p "$dir"; fi
    if [ -e "$dir" ] || [ -L "$dir" ]; then checkdir "$dir" "$owner"; fi
    if [ -L "$dst" ]; then
      cur=$(/usr/bin/readlink "$dst")
      if [ "$cur" = "$src" ]; then exit 0; fi
      case "$cur" in
        */Lidless.app/Contents/Helpers/lidless) if [ "$mode" = install ]; then /bin/rm -- "$dst"; fi ;;
        *) fail "$dst already links to $cur. Remove it first if you want Lidless to install there." ;;
      esac
    elif [ -e "$dst" ]; then
      fail "$dst already exists. Remove it first if you want Lidless to install there."
    fi
    if [ "$mode" != install ]; then exit 0; fi
    /bin/ln -sn "$src" "$dst"
    if [ ! -L "$dst" ] || [ "$(/usr/bin/readlink "$dst")" != "$src" ]; then fail "Couldn't create $dst."; fi
    """

    /// Arguments for running `installProgram` directly with `/bin/sh`.
    public static func installArguments(mode: String, toolPath: String,
                                        destination: String = installPath, owner: UInt32) -> [String] {
        ["-c", installProgram, "lidless-install", mode, toolPath, destination, String(owner)]
    }

    /// AppleScript that runs `installProgram` as root with an admin prompt.
    /// Every argument goes through `quoted form of` for the shell and is escaped
    /// for the AppleScript literal, so a quote in a folder name stays a character.
    public static func installScript(toolPath: String, destination: String = installPath) -> String {
        "do shell script \"/bin/sh -c \" & quoted form of " + appleScriptLiteral(installProgram)
            + " & \" lidless-install install \" & quoted form of " + appleScriptLiteral(toolPath)
            + " & \" \" & quoted form of " + appleScriptLiteral(destination)
            + " & \" 0\" with administrator privileges"
    }

    /// A string as an AppleScript string literal, quotes included.
    public static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
