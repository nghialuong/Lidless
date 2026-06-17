import Foundation

/// Controls the macOS `SleepDisabled` flag (IOPMrootDomain).
///
/// M1 implementation shells out to `pmset -a disablesleep` via `osascript`
/// with administrator privileges, so toggling prompts for the admin password.
///
/// TODO (M1.5): replace with a privileged helper installed via `SMAppService`
/// that sets the flag over XPC — password-less, plus a heartbeat watchdog that
/// auto-clears the flag if the app dies (so the Mac can never get stuck awake).
struct PowerManager {

    /// Read the current `SleepDisabled` flag from `pmset -g`.
    func isSleepDisabled() -> Bool {
        guard let out = Shell.capture("/usr/bin/pmset", ["-g"]) else { return false }
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.lowercased()
            if line.contains("sleepdisabled") {
                return line.contains(" 1")
            }
        }
        return false
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
