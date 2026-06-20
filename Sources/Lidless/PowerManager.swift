import Foundation

/// Controls the macOS `SleepDisabled` flag (IOPMrootDomain).
///
/// This is the **fallback** path, used only when the privileged helper isn't
/// installed: it shells out to `pmset -a disablesleep` via `osascript` with
/// administrator privileges, so toggling prompts for the admin password.
///
/// The primary path is `HelperManager`, which sets the flag over XPC through a
/// root helper installed via `SMAppService` — password-less, plus a heartbeat
/// watchdog that auto-clears the flag if the app dies.
struct PowerManager {

    /// Read the current `SleepDisabled` flag from `pmset -g`.
    func isSleepDisabled() -> Bool {
        guard let out = Shell.capture("/usr/bin/pmset", ["-g"]) else { return false }
        return PowerParsers.isSleepDisabled(pmsetG: out)
    }

    /// Set or clear the flag. Throws with the underlying error message on failure
    /// (including the user cancelling the admin prompt).
    func setSleepDisabled(_ enabled: Bool) throws {
        let value = enabled ? "1" : "0"
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw NSError(
                domain: "Lidless.PowerManager",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Authorization cancelled." : msg]
            )
        }
    }
}
