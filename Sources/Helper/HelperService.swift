import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: LidlessHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// The actual privileged work. Runs as root, so it can call `pmset` directly
/// with no admin prompt. Guards against a stuck-awake state with a watchdog.
final class HelperService: NSObject, LidlessHelperProtocol {
    private let queue = DispatchQueue(label: "com.nghialuong.lidless.helper.state")
    private var lastHeartbeat = Date()
    private var keepAwake = false
    private let watchdogTimeout: TimeInterval = 90
    private var watchdogTimer: DispatchSourceTimer?

    override init() {
        super.init()
        startWatchdog()
    }

    // MARK: LidlessHelperProtocol

    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let result = self.runPmset(disableSleep: enabled)
            if result.ok {
                self.keepAwake = enabled
                self.lastHeartbeat = Date()
            }
            reply(result.ok, result.error)
        }
    }

    func getState(withReply reply: @escaping (Bool) -> Void) {
        let out = Self.capture("/usr/bin/pmset", ["-g"]) ?? ""
        reply(PowerParsers.isSleepDisabled(pmsetG: out))
    }

    func heartbeat(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            self.lastHeartbeat = Date()
            reply(true)
        }
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply("0.1.0")
    }

    // MARK: Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.keepAwake else { return }
            if Watchdog.shouldAutoRestore(lastHeartbeat: self.lastHeartbeat,
                                          now: Date(),
                                          timeout: self.watchdogTimeout) {
                _ = self.runPmset(disableSleep: false)
                self.keepAwake = false
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: Shell

    @discardableResult
    private func runPmset(disableSleep: Bool) -> (ok: Bool, error: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-a", "disablesleep", disableSleep ? "1" : "0"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return (false, error.localizedDescription)
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (false, msg.isEmpty ? "pmset exited \(proc.terminationStatus)" : msg)
        }
        return (true, nil)
    }

    private static func capture(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
