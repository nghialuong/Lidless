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
