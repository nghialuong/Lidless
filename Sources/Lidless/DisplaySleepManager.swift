import Foundation

/// Turns the displays off without changing the Mac's system-sleep policy.
struct DisplaySleepManager {
    private let executable = "/usr/bin/pmset"

    func sleepNow() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["displaysleepnow"]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Couldn’t turn off the display."
            throw NSError(
                domain: "Lidless.DisplaySleepManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
}
