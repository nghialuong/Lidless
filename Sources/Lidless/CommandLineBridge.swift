import Foundation

/// Hears `lidless off`, hands it to the app's own switch, and replies once the
/// outcome is known.
///
/// Registered with `.deliverImmediately`: a menu-bar app is almost never the
/// active app, and the default suspension behaviour would hold the request until
/// the user next clicked the menu — long after the script that sent it gave up.
final class CommandLineBridge: NSObject {
    private let appBundleID: String
    private let onStop: @MainActor (_ reply: @escaping (Bool, String?) -> Void) -> Void

    init(appBundleID: String,
         onStop: @escaping @MainActor (_ reply: @escaping (Bool, String?) -> Void) -> Void) {
        self.appBundleID = appBundleID
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
        // A request without an id has no tool waiting on a reply, but it is still
        // a request to stop.
        let requestID = notification.userInfo?[LidlessCLI.UserInfoKey.requestID] as? String
        Task { @MainActor in
            self.onStop { [appBundleID] ok, message in
                guard let requestID else { return }
                var info: [String: Any] = [LidlessCLI.UserInfoKey.requestID: requestID,
                                           LidlessCLI.UserInfoKey.ok: ok]
                if let message { info[LidlessCLI.UserInfoKey.message] = message }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(LidlessCLI.stoppedNotificationName(appBundleID: appBundleID)),
                    object: nil, userInfo: info, deliverImmediately: true
                )
            }
        }
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
    ///
    /// Checks the destination as the user first, so a conflict is reported
    /// without a password prompt. The privileged run checks again itself:
    /// anything can change between the two.
    static func install() throws {
        try run("/bin/sh", LidlessCLI.installArguments(mode: "check",
                                                     toolPath: bundledToolURL.path,
                                                     owner: 0))
        try run("/usr/bin/osascript", ["-e", LidlessCLI.installScript(toolPath: bundledToolURL.path)])
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
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
