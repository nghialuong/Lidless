import Foundation

/// Hears `lidless off` and hands it to the app's own switch.
///
/// Registered with `.deliverImmediately`: a menu-bar app is almost never the
/// active app, and the default suspension behaviour would hold the request until
/// the user next clicked the menu — long after the script that sent it gave up.
final class CommandLineBridge: NSObject {
    private let onStop: @MainActor () -> Void

    init(appBundleID: String, onStop: @escaping @MainActor () -> Void) {
        self.onStop = onStop
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(stopRequested(_:)),
            name: Notification.Name(LidlessCLI.stopNotificationName(appBundleID: appBundleID)),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func stopRequested(_ notification: Notification) {
        Task { @MainActor in self.onStop() }
    }
}

/// Links the bundled `lidless` tool onto the PATH.
enum CommandLineToolInstaller {
    static var bundledToolURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lidless")
    }

    /// True only when the link points at *this* app's tool, so a stale link left
    /// by a moved or deleted copy reads as not installed.
    static var isInstalled: Bool {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: LidlessCLI.installPath) else { return false }
        return URL(fileURLWithPath: destination).standardizedFileURL
            == bundledToolURL.standardizedFileURL
    }

    /// `/usr/local/bin` is root-owned on Apple Silicon, so this asks for the
    /// admin password, the same way `PowerManager` does without the helper.
    static func install() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", LidlessCLI.installScript(toolPath: bundledToolURL.path)]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "Lidless.CommandLineToolInstaller",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Authorization cancelled." : msg]
            )
        }
    }
}
