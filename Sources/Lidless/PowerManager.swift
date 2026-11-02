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
    ///
    /// Returns nil whenever the flag wasn't actually observed — `pmset` failed to
    /// launch, exited non-zero, or printed something that doesn't state the flag.
    /// A failed read must never collapse into "off".
    ///
    /// Reading needs no privileges, so this is the app's read path whether or not
    /// the helper is installed; the helper is only needed to *change* the flag.
    func isSleepDisabled() -> Bool? {
        guard let out = Shell.capture("/usr/bin/pmset", ["-g"]) else { return nil }
        return PowerParsers.sleepDisabled(pmsetG: out)
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
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? L10n.tr("Unknown error")
            throw NSError(
                domain: "Lidless.PowerManager",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? L10n.tr("Authorization cancelled.") : msg]
            )
        }
    }
}
