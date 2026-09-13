import Darwin
import Foundation

/// A monotonic absolute deadline shared by an entire operation and every child
/// process it starts. Wall-clock changes cannot extend safety-critical work.
public struct ProcessDeadline: Equatable {
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public init(after interval: TimeInterval) {
        let nanos = UInt64(max(0, interval) * 1_000_000_000)
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds &+ nanos
    }

    public func remaining(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> TimeInterval {
        guard uptimeNanoseconds > now else { return 0 }
        return TimeInterval(uptimeNanoseconds - now) / 1_000_000_000
    }

    public func capped(to interval: TimeInterval,
                       now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> ProcessDeadline {
        let cap = now &+ UInt64(max(0, interval) * 1_000_000_000)
        return ProcessDeadline(uptimeNanoseconds: min(uptimeNanoseconds, cap))
    }

    /// Move the deadline earlier so cleanup or a mandatory following phase has
    /// time reserved inside the original absolute bound.
    public func reserving(_ interval: TimeInterval) -> ProcessDeadline {
        let nanos = UInt64(max(0, interval) * 1_000_000_000)
        return ProcessDeadline(
            uptimeNanoseconds: nanos >= uptimeNanoseconds ? 0 : uptimeNanoseconds - nanos
        )
    }
}

/// Mechanical timing limits for the unplug-to-verified-off path.
public enum SafetyTiming {
    /// One fixed `pmset` read, including process termination and pipe cleanup.
    public static let readTimeout: TimeInterval = 0.25
    /// One helper operation, from helper admission through any corrective OFF.
    public static let helperOperationTimeout: TimeInterval = 3.4
    /// An enable gets only this prefix; the remainder is reserved for OFF.
    public static let helperEnablePhaseTimeout: TimeInterval = 0.8
    /// Each fixed `pmset` process, including its cleanup, has this smaller cap.
    public static let helperProcessTimeout: TimeInterval = 0.25
    /// XPC transport/admission margin beyond the helper's own deadline.
    public static let helperTransportMargin: TimeInterval = 0.25
    /// The complete helper-reply phase, including transport and helper queuing.
    public static var helperReplyTimeout: TimeInterval {
        helperOperationTimeout + helperTransportMargin
    }
    /// Interactive fallback is separate from helper safety work.
    public static let authorizationTimeout: TimeInterval = 3.4
    /// The runner begins termination this far before its caller's deadline.
    public static let terminateGrace: TimeInterval = 0.06
    /// Pipe draining is diagnostic and receives only this reserved tail.
    public static let drainGrace: TimeInterval = 0.02

    /// Initial power read + helper reply + independent final read. Those phases
    /// all share an absolute notification-entry deadline in the app; spelling
    /// the serial critical path out here makes the sub-five-second claim
    /// mechanically testable and leaves meaningful scheduling margin.
    public static var maximumUnplugResponse: TimeInterval {
        readTimeout + helperReplyTimeout + readTimeout
    }
}

public enum DeadlineProcessFailure: Error, Equatable {
    case launch(String)
    case timedOut
    case cancelled
    case exited(status: Int32, standardError: String)
    /// SIGTERM and SIGKILL could not establish that the launched process can no
    /// longer execute. Callers must treat this as an unsafe write outcome.
    case terminationUnconfirmed
}

public struct DeadlineProcessOutput: Equatable {
    public let standardOutput: Data
    public let standardError: Data

    public init(standardOutput: Data, standardError: Data) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs one fixed executable without ever waiting indefinitely. stdout and
/// stderr are drained concurrently, preventing either pipe from filling. On a
/// deadline or cancellation the child is terminated, then force-killed after a
/// short grace period.
public enum DeadlineProcessRunner {
    private static let pollInterval: TimeInterval = 0.02
    private static let maximumCapturedBytes = 64 * 1_024

    public static func run(executable: String,
                           arguments: [String],
                           deadline: ProcessDeadline,
                           cancelled: () -> Bool = { false }) -> Result<DeadlineProcessOutput, DeadlineProcessFailure> {
        precondition(!Thread.isMainThread, "DeadlineProcessRunner must run off the main thread")

        let cleanupReserve = SafetyTiming.terminateGrace + SafetyTiming.drainGrace
        let executionDeadline = deadline.reserving(cleanupReserve)
        guard !cancelled(), executionDeadline.remaining() > 0 else {
            return .failure(cancelled() ? .cancelled : .timedOut)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.launch(error.localizedDescription))
        }

        // The child owns duplicated write descriptors now. Closing the parent's
        // copies lets the drainers observe EOF as soon as the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let drainGroup = DispatchGroup()
        let outputLock = NSLock()
        var stdout = Data()
        var stderr = Data()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = drain(stdoutPipe.fileHandleForReading)
            outputLock.lock()
            stdout = data
            outputLock.unlock()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = drain(stderrPipe.fileHandleForReading)
            outputLock.lock()
            stderr = data
            outputLock.unlock()
            drainGroup.leave()
        }

        var interruption: DeadlineProcessFailure?
        while true {
            if cancelled() {
                interruption = .cancelled
                break
            }
            let remaining = executionDeadline.remaining()
            if remaining <= 0 {
                interruption = .timedOut
                break
            }
            if terminated.wait(timeout: .now() + min(pollInterval, remaining)) == .success {
                break
            }
        }

        if let interruption {
            let terminationDeadline = deadline.reserving(SafetyTiming.drainGrace)
            if process.isRunning {
                process.terminate()
            }
            let gracefulWait = min(SafetyTiming.terminateGrace,
                                   terminationDeadline.remaining())
            var confirmed = !process.isRunning ||
                (gracefulWait > 0 &&
                 terminated.wait(timeout: .now() + gracefulWait) == .success)

            if !confirmed, process.isRunning {
                let killResult = Darwin.kill(process.processIdentifier, SIGKILL)
                let killWasAccepted = killResult == 0 ||
                    (killResult == -1 && errno == ESRCH)
                let remaining = terminationDeadline.remaining()
                if remaining > 0,
                   terminated.wait(timeout: .now() + remaining) == .success {
                    confirmed = true
                } else {
                    // An accepted SIGKILL guarantees the direct child cannot
                    // execute more user-space mutation, even if reaping lags.
                    confirmed = !process.isRunning || killWasAccepted
                }
            }

            // Draining is diagnostic, but it is still charged to the original
            // deadline. No sequence of cleanup waits can extend that deadline.
            let drainRemaining = deadline.remaining()
            if drainRemaining > 0 {
                _ = drainGroup.wait(timeout: .now() + drainRemaining)
            }
            guard confirmed else { return .failure(.terminationUnconfirmed) }
            return .failure(interruption)
        }

        let drainRemaining = deadline.remaining()
        if drainRemaining > 0 {
            _ = drainGroup.wait(timeout: .now() + drainRemaining)
        }
        outputLock.lock()
        let capturedOutput = stdout
        let capturedError = stderr
        outputLock.unlock()

        guard process.terminationStatus == 0 else {
            let message = String(data: capturedError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(.exited(status: process.terminationStatus,
                                    standardError: message))
        }
        return .success(DeadlineProcessOutput(standardOutput: capturedOutput,
                                              standardError: capturedError))
    }

    private static func drain(_ handle: FileHandle) -> Data {
        var captured = Data()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 4_096),
                      !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            let available = maximumCapturedBytes - captured.count
            if available > 0 {
                captured.append(chunk.prefix(available))
            }
        }
        return captured
    }
}
