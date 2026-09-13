import Foundation
import OSLog

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    /// The app this helper belongs to, recovered from the label launchd started
    /// us with. The Debug and Release builds run separate daemons under separate
    /// labels, so each ends up demanding its own app and not the other's.
    private let appBundleID = LidlessHelper.appBundleID(
        fromLabel: LidlessHelper.activeLabel(
            machLabel: ProcessInfo.processInfo.environment[LidlessHelper.machLabelEnvKey]
        )
    )

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Require the peer be our app before handing it an object that runs as
        // root. Without this, the check amounts to "did something on this Mac
        // connect", which every process passes.
        //
        // `setCodeSigningRequirement` validates against the peer's audit token
        // on each message, so it has none of the PID-reuse race that inspecting
        // `processIdentifier` would. It must be set before `resume()`, and it is
        // an XPC error to set it twice — hence here, once, on a fresh connection.
        newConnection.setCodeSigningRequirement(
            LidlessHelper.codeSigningRequirement(appBundleID: appBundleID)
        )
        newConnection.exportedInterface = NSXPCInterface(with: LidlessHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// The actual privileged work. Runs as root, so it can call `pmset` directly
/// with no admin prompt. Guards against a stuck-awake state with a watchdog.
final class HelperService: NSObject, LidlessHelperProtocol {
    private static let serviceLabel = LidlessHelper.activeLabel(
        machLabel: ProcessInfo.processInfo.environment[LidlessHelper.machLabelEnvKey]
    )
    private static let logger = Logger(
        subsystem: serviceLabel,
        category: "sleep-state"
    )
    typealias Reply = (Bool, String?) -> Void

    private struct PendingRequest {
        let enabled: Bool
        let operationID: UInt64
        var deadline: ProcessDeadline
        var replies: [Reply]
    }

    /// One worker drains a bounded admission buffer rather than one dispatch
    /// block per client call. OFF has priority and duplicate pending OFFs share
    /// one physical operation.
    private let queue = DispatchQueue(
        label: LidlessHelper.diagnosticQueueLabel(
            machLabel: HelperService.serviceLabel,
            component: "state"
        )
    )
    private let watchdogQueue = DispatchQueue(
        label: LidlessHelper.diagnosticQueueLabel(
            machLabel: HelperService.serviceLabel,
            component: "watchdog"
        )
    )
    private let operationLock = NSLock()
    private var latestOperationID: UInt64 = 0
    private var pendingEnable: PendingRequest?
    private var pendingOff: PendingRequest?
    private var workerScheduled = false
    private var lastHeartbeatUptime = DispatchTime.now().uptimeNanoseconds
    /// Unknown startup state is potentially awake until a strict read proves off.
    private var keepAwake = true
    private let watchdogTimeout: TimeInterval = 90
    private var watchdogTimer: DispatchSourceTimer?

    override init() {
        super.init()
        queue.async { [weak self] in self?.recoverWatchdogOwnership() }
        startWatchdog()
    }

    deinit {
        watchdogTimer?.cancel()
    }

    // MARK: LidlessHelperProtocol

    func setKeepAwake(_ enabled: Bool,
                      deadlineUptimeNanoseconds: UInt64,
                      withReply reply: @escaping Reply) {
        let clientDeadline = ProcessDeadline(
            uptimeNanoseconds: deadlineUptimeNanoseconds
        )
        let deadline = clientDeadline.capped(to: SafetyTiming.helperOperationTimeout)
        enqueue(enabled: enabled, deadline: deadline, reply: reply)
    }

    func getState(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            let deadline = ProcessDeadline(after: SafetyTiming.readTimeout)
            reply(self.readSleepDisabled(deadline: deadline, cancelled: { false }) ?? false)
        }
    }

    func heartbeat(withReply reply: @escaping (Bool) -> Void) {
        // Heartbeats must not wait behind client mutation backlog.
        operationLock.lock()
        lastHeartbeatUptime = DispatchTime.now().uptimeNanoseconds
        operationLock.unlock()
        reply(true)
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply("0.1.0")
    }

    // MARK: Operation admission and ordering

    private func enqueue(enabled: Bool,
                         deadline: ProcessDeadline,
                         reply: Reply? = nil) {
        var supersededReplies: [Reply] = []
        var shouldSchedule = false

        operationLock.lock()
        latestOperationID &+= 1
        let operationID = latestOperationID
        let admission = HelperQueuePolicy.admission(
            requestedEnable: enabled,
            hasPendingEnable: pendingEnable != nil,
            hasPendingOff: pendingOff != nil
        )

        if enabled {
            if admission == .replacePendingEnable,
               let previous = pendingEnable {
                supersededReplies.append(contentsOf: previous.replies)
            }
            pendingEnable = PendingRequest(
                enabled: true,
                operationID: operationID,
                deadline: deadline,
                replies: reply.map { [$0] } ?? []
            )
        } else {
            if admission == .coalescePendingOff,
               var existing = pendingOff {
                existing.deadline = ProcessDeadline(
                    uptimeNanoseconds: min(existing.deadline.uptimeNanoseconds,
                                           deadline.uptimeNanoseconds)
                )
                if let reply { existing.replies.append(reply) }
                pendingOff = existing
            } else {
                pendingOff = PendingRequest(
                    enabled: false,
                    operationID: operationID,
                    deadline: deadline,
                    replies: reply.map { [$0] } ?? []
                )
            }
            // A pending enable can no longer be current once OFF is admitted.
            if let previous = pendingEnable {
                supersededReplies.append(contentsOf: previous.replies)
                pendingEnable = nil
            }
        }

        if !workerScheduled {
            workerScheduled = true
            shouldSchedule = true
        }
        operationLock.unlock()

        for superseded in supersededReplies {
            superseded(false, "Superseded by a newer sleep-state request.")
        }
        if shouldSchedule {
            queue.async { [weak self] in self?.drainRequests() }
        }
    }

    private func drainRequests() {
        while let request = takeNextRequest() {
            execute(request)
        }
    }

    private func takeNextRequest() -> PendingRequest? {
        operationLock.lock()
        defer { operationLock.unlock() }
        switch HelperQueuePolicy.nextTarget(
            hasPendingEnable: pendingEnable != nil,
            hasPendingOff: pendingOff != nil
        ) {
        case .some(false):
            defer { pendingOff = nil }
            return pendingOff
        case .some(true):
            defer { pendingEnable = nil }
            return pendingEnable
        case .none:
            workerScheduled = false
            return nil
        }
    }

    private func execute(_ request: PendingRequest) {
        let enabled = request.enabled
        guard HelperOperationPolicy.shouldStart(
            requestedEnable: enabled,
            isCurrent: isCurrent(request.operationID)
        ), request.deadline.remaining() > 0 else {
            reply(request, ok: false, error: "Superseded or timed out before execution.")
            return
        }

        let writeDeadline = enabled
            ? request.deadline.capped(to: SafetyTiming.helperEnablePhaseTimeout)
            : request.deadline
        let result = setAndVerify(
            disableSleep: enabled,
            deadline: writeDeadline,
            cancelled: {
                HelperOperationPolicy.shouldCancel(
                    requestedEnable: enabled,
                    isCurrent: self.isCurrent(request.operationID)
                )
            }
        )

        if result.ok, (!enabled || isCurrent(request.operationID)) {
            setWatchdogOwnership(enabled)
            reply(request, ok: true, error: nil)
            return
        }

        if enabled {
            Self.logger.fault("enable_failed fail_closed_disable_started")
            let restored = setAndVerify(
                disableSleep: false,
                deadline: request.deadline,
                cancelled: { false }
            )
            setWatchdogOwnership(
                HelperSafetyPolicy.keepAwakeAfterFailedWrite(
                    requestedEnable: true,
                    restoreSucceeded: restored.ok
                )
            )
        } else {
            setWatchdogOwnership(
                HelperSafetyPolicy.keepAwakeAfterFailedWrite(
                    requestedEnable: false,
                    restoreSucceeded: false
                )
            )
        }
        let error = result.error ??
            (enabled ? "Superseded by a newer sleep-state request." : "SleepDisabled operation failed.")
        reply(request, ok: false, error: error)
    }

    private func reply(_ request: PendingRequest, ok: Bool, error: String?) {
        for callback in request.replies {
            callback(ok, error)
        }
    }

    private func isCurrent(_ operationID: UInt64) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return operationID == latestOperationID
    }

    private func setWatchdogOwnership(_ enabled: Bool) {
        operationLock.lock()
        keepAwake = enabled
        lastHeartbeatUptime = DispatchTime.now().uptimeNanoseconds
        operationLock.unlock()
    }

    // MARK: Watchdog

    private func recoverWatchdogOwnership() {
        let observed = readSleepDisabled(
            deadline: ProcessDeadline(after: SafetyTiming.readTimeout),
            cancelled: { false }
        )
        operationLock.lock()
        keepAwake = HelperRecoveryPolicy.potentiallyKeepsAwake(observed: observed)
        operationLock.unlock()
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.operationLock.lock()
            let ownsPotentialWake = self.keepAwake
            let lastHeartbeat = self.lastHeartbeatUptime
            self.operationLock.unlock()
            guard ownsPotentialWake,
                  Watchdog.shouldAutoRestore(
                      lastHeartbeatUptime: lastHeartbeat,
                      nowUptime: now,
                      timeout: self.watchdogTimeout
                  ) else { return }

            Self.logger.notice("watchdog_restore_queued")
            let deadline = ProcessDeadline(after: SafetyTiming.helperOperationTimeout)
            self.enqueue(enabled: false, deadline: deadline)
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: Shell

    /// The helper is the sole retry owner for helper-backed writes. All attempts,
    /// delays, read-backs, and failed-enable correction share one absolute
    /// operation deadline.
    private func setAndVerify(disableSleep target: Bool,
                              deadline: ProcessDeadline,
                              cancelled: () -> Bool) -> (ok: Bool, error: String?) {
        var latestError: String?
        for attempt in 1...VerifiedWritePolicy.maximumAttempts {
            guard deadline.remaining() > 0 else {
                return (false, "SleepDisabled operation timed out.")
            }
            if cancelled() {
                return (false, "Superseded by a newer sleep-state request.")
            }

            Self.logger.info(
                "write_attempt target=\(target, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
            let written = runPmset(disableSleep: target,
                                   deadline: deadline,
                                   cancelled: cancelled)
            latestError = written.error
            let observed = readSleepDisabled(deadline: deadline,
                                             cancelled: cancelled)
            let observedText = observed.map { $0 ? "true" : "false" } ?? "unknown"
            Self.logger.info(
                "write_verification target=\(target, privacy: .public) attempt=\(attempt, privacy: .public) command_ok=\(written.ok, privacy: .public) observed=\(observedText, privacy: .public)"
            )

            switch VerifiedWritePolicy.decision(target: target,
                                                attempt: attempt,
                                                writeSucceeded: written.ok,
                                                observed: observed) {
            case .verified:
                Self.logger.notice(
                    "write_terminal outcome=verified target=\(target, privacy: .public) attempts=\(attempt, privacy: .public)"
                )
                return (true, nil)

            case .retry(_, let failure):
                guard let delay = VerifiedWritePolicy.retryDelay(
                    afterAttempt: attempt,
                    remaining: deadline.remaining()
                ) else {
                    return (false, failureMessage(failure, underlying: latestError))
                }
                Self.logger.warning(
                    "write_retry target=\(target, privacy: .public) attempt=\(attempt, privacy: .public) failure=\(String(describing: failure), privacy: .public) delay_ms=\(Int(delay * 1_000), privacy: .public)"
                )
                guard sleep(delay, before: deadline, cancelled: cancelled) else {
                    return (false, "SleepDisabled operation cancelled or timed out.")
                }

            case .terminal(let failure):
                Self.logger.error(
                    "write_terminal outcome=failed target=\(target, privacy: .public) attempts=\(attempt, privacy: .public) failure=\(String(describing: failure), privacy: .public)"
                )
                return (false, failureMessage(failure, underlying: latestError))
            }
        }
        return (false, "SleepDisabled verification failed.")
    }

    private func runPmset(disableSleep: Bool,
                          deadline: ProcessDeadline,
                          cancelled: () -> Bool) -> (ok: Bool, error: String?) {
        let result = DeadlineProcessRunner.run(
            executable: "/usr/bin/pmset",
            arguments: ["-a", "disablesleep", disableSleep ? "1" : "0"],
            deadline: deadline.capped(to: SafetyTiming.helperProcessTimeout),
            cancelled: cancelled
        )
        switch result {
        case .success:
            return (true, nil)
        case .failure(let failure):
            return (false, processFailureMessage(failure))
        }
    }

    private func readSleepDisabled(deadline: ProcessDeadline,
                                   cancelled: () -> Bool) -> Bool? {
        let result = DeadlineProcessRunner.run(
            executable: "/usr/bin/pmset",
            arguments: ["-g"],
            deadline: deadline.capped(to: SafetyTiming.helperProcessTimeout),
            cancelled: cancelled
        )
        guard case .success(let output) = result,
              let text = String(data: output.standardOutput, encoding: .utf8) else {
            return nil
        }
        return PowerParsers.sleepDisabled(pmsetG: text)
    }

    private func sleep(_ delay: TimeInterval,
                       before deadline: ProcessDeadline,
                       cancelled: () -> Bool) -> Bool {
        let end = ProcessDeadline(after: min(delay, deadline.remaining()))
        while end.remaining() > 0 {
            if cancelled() || deadline.remaining() <= 0 { return false }
            Thread.sleep(forTimeInterval: min(0.02, end.remaining()))
        }
        return !cancelled() && deadline.remaining() > 0
    }

    private func failureMessage(_ failure: VerifiedWriteFailure,
                                underlying: String?) -> String {
        switch failure {
        case .writeFailed:
            return underlying ?? "pmset failed."
        case .readFailed:
            return "Couldn’t read back SleepDisabled."
        case .mismatch(let actual):
            return "SleepDisabled read back as \(actual ? 1 : 0)."
        }
    }

    private func processFailureMessage(_ failure: DeadlineProcessFailure) -> String {
        switch failure {
        case .launch(let message):
            return message
        case .timedOut:
            return "pmset timed out."
        case .cancelled:
            return "pmset was superseded."
        case .terminationUnconfirmed:
            return "pmset termination could not be confirmed."
        case .exited(let status, let standardError):
            return standardError.isEmpty ? "pmset exited \(status)." : standardError
        }
    }
}
