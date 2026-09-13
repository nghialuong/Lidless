import Foundation

/// A change to the system `SleepDisabled` flag made outside this app — `pmset`
/// in Terminal, the helper's watchdog, or another build of Lidless.
public enum ExternalChange: Equatable {
    case enabledOutside
    case disabledOutside

    public var nowEnabled: Bool { self == .enabledOutside }

    /// Describes the *event*, not the resulting state: a safety auto-pause can
    /// flip the state back while this notice is still on screen.
    public var message: String {
        switch self {
        case .enabledOutside:  return "Sleep prevention was turned on outside Lidless."
        case .disabledOutside: return "Sleep prevention was turned off outside Lidless."
        }
    }
}

/// Why keep-awake is being set. Alert presentation and notice lifecycle key off
/// this rather than a bare "was this the user?" flag.
public enum SetOrigin: Equatable {
    /// The menu-bar toggle, or a control in Settings.
    case user
    /// Battery or thermal policy pausing keep-awake.
    case safety
    /// The auto-off timer elapsed.
    case autoOff
    /// Auto-enable mode deriving the live state from the armed intent — including
    /// the write that settles its last outstanding one as the user leaves the
    /// mode. Distinct from `.safety` because this origin can turn keep-awake *on*
    /// as well as off, and it isn't the user acting on the switch — so it must
    /// never present an alert or disturb a notice they haven't seen yet.
    case auto
}


/// Pure decision logic for keeping the UI in step with the real system flag.
///
/// Everything here is a static function over explicit inputs — no AppKit, no
/// XPC — so the behaviour that matters can be tested directly, the way
/// `SafetyEvaluator` and `AutoOff` are.
public enum StateReconciler {

    // MARK: Reconciling a fresh read

    public enum Outcome: Equatable {
        /// The read failed. Keep showing the last-known state.
        case unknown
        /// The read agrees with the UI. Record a baseline; change nothing else.
        case inSync
        /// First confirmed read of the session, and it differs. Adopt silently.
        case adopt(enabled: Bool)
        /// The flag moved underneath us. Adopt it and say so.
        case drift(ExternalChange)
    }

    /// - Parameters:
    ///   - shown: what the UI currently displays.
    ///   - hasBaseline: whether the flag has been read successfully this session.
    ///   - observed: the fresh reading; `nil` when the read failed.
    ///
    /// An agreeing read is `.inSync` whether or not a baseline exists, so
    /// `.adopt` and `.drift` always imply a real transition. That's what keeps
    /// the 30-second poll from re-arming timers it already armed.
    ///
    /// Without a baseline the first differing read adopts silently: `shown` is
    /// still just its `false` default, so calling that an external change would
    /// accuse somebody of something that never happened — a relaunch inside the
    /// helper watchdog's window, for instance.
    public static func reconcile(shown: Bool, hasBaseline: Bool, observed: Bool?) -> Outcome {
        guard let observed else { return .unknown }
        if observed == shown { return .inSync }
        guard hasBaseline else { return .adopt(enabled: observed) }
        return .drift(observed ? .enabledOutside : .disabledOutside)
    }

    // MARK: Notice lifecycle

    /// The "changed outside Lidless" notice is the user's only explanation for a
    /// toggle that moved by itself, so only the user acting on it clears it.
    ///
    /// This matters most in one specific case: adopting an externally-enabled
    /// flag can immediately trip a safety pause, and if that pause cleared the
    /// notice, the explanation would vanish at the exact moment it's needed.
    public static func clearsExternalNotice(_ origin: SetOrigin) -> Bool {
        origin == .user
    }

}
/// Why a requested `SleepDisabled` value could not be verified.
public enum VerifiedWriteFailure: Equatable {
    case writeFailed
    case readFailed
    case mismatch(actual: Bool)
}

/// The bounded retry decision after one write plus its mandatory read-back.
public enum VerifiedWriteDecision: Equatable {
    case verified
    case retry(after: TimeInterval, failure: VerifiedWriteFailure)
    case terminal(failure: VerifiedWriteFailure)
}

/// Pure retry and fail-closed policy for verified global writes.
public enum VerifiedWritePolicy {
    public static let maximumAttempts = 3
    public static let retryDelays: [TimeInterval] = [0.15, 0.35]

    public static func decision(target: Bool,
                                attempt: Int,
                                writeSucceeded: Bool,
                                observed: Bool?) -> VerifiedWriteDecision {
        let failure: VerifiedWriteFailure?
        if !writeSucceeded {
            failure = .writeFailed
        } else if let observed {
            failure = observed == target ? nil : .mismatch(actual: observed)
        } else {
            failure = .readFailed
        }

        guard let failure else { return .verified }
        guard attempt < maximumAttempts else { return .terminal(failure: failure) }
        return .retry(after: retryDelays[attempt - 1], failure: failure)
    }

    /// A retry may start only when its delay fits inside the operation's
    /// remaining absolute deadline.
    public static func retryDelay(afterAttempt attempt: Int,
                                  remaining: TimeInterval) -> TimeInterval? {
        guard attempt > 0, attempt < maximumAttempts else { return nil }
        let delay = retryDelays[attempt - 1]
        return delay < remaining ? delay : nil
    }

    /// Any terminally uncertain enable is followed by OFF. A momentary `false`
    /// read cannot prove that a timed-out helper enable will not execute later.
    public static func requiresFailClosedCorrection(target: Bool,
                                                    writeSucceeded: Bool,
                                                    observed: Bool?) -> Bool {
        target && (!writeSucceeded || observed != true)
    }
}

/// Pure bookkeeping for failure paths owned by the privileged helper.
public enum HelperSafetyPolicy {
    public static func keepAwakeAfterFailedWrite(requestedEnable: Bool,
                                                restoreSucceeded: Bool) -> Bool {
        requestedEnable ? !restoreSucceeded : true
    }

    public static func keepAwakeAfterWatchdogAttempt(previous: Bool,
                                                     restoreSucceeded: Bool) -> Bool {
        previous && !restoreSucceeded
    }
}

/// Coalescing rule for serial helper work. OFF is never discarded or cancelled;
/// stale enables are skipped before launch and interrupted while running.
public enum HelperOperationPolicy {
    public static func shouldStart(requestedEnable: Bool,
                                   isCurrent: Bool) -> Bool {
        !requestedEnable || isCurrent
    }

    public static func shouldCancel(requestedEnable: Bool,
                                    isCurrent: Bool) -> Bool {
        requestedEnable && !isCurrent
    }
}

public enum HelperQueueAdmission: Equatable {
    case enqueue
    case replacePendingEnable
    case coalescePendingOff
}

/// Admission and priority rules for the helper's bounded backlog. There can be
/// one pending enable and one pending OFF; OFF is always selected first.
public enum HelperQueuePolicy {
    public static func admission(requestedEnable: Bool,
                                 hasPendingEnable: Bool,
                                 hasPendingOff: Bool) -> HelperQueueAdmission {
        if requestedEnable {
            return hasPendingEnable ? .replacePendingEnable : .enqueue
        }
        return hasPendingOff ? .coalescePendingOff : .enqueue
    }

    public static func nextTarget(hasPendingEnable: Bool,
                                  hasPendingOff: Bool) -> Bool? {
        if hasPendingOff { return false }
        if hasPendingEnable { return true }
        return nil
    }
}

/// A restarted helper conservatively owns an unreadable global state until a
/// strict `SleepDisabled` read proves it is off.
public enum HelperRecoveryPolicy {
    public static func potentiallyKeepsAwake(observed: Bool?) -> Bool {
        observed != false
    }
}

/// Serialized authorization writes never cancel OFF. A newer mutation may
/// interrupt only an older enable, after which the serial owner runs OFF first.
public enum AuthorizationMutationPolicy {
    public static func shouldCancel(requestedEnable: Bool,
                                    isCurrent: Bool) -> Bool {
        requestedEnable && !isCurrent
    }
}

/// Charging-gated activation is safe only with a live transition source and the
/// authenticated helper. Polling remains a recovery signal, not authorization.
public enum PowerNotificationPolicy {
    public static func allowsChargingGatedEnable(subscriptionActive: Bool,
                                                 signedHelperAvailable: Bool) -> Bool {
        subscriptionActive && signedHelperAvailable
    }
}

/// Generation tokens reject an entire stale power sample before it changes
/// display state or authorizes reconciliation.
public struct PowerSampleGeneration: Equatable {
    public struct Token: Equatable {
        fileprivate let value: UInt64
    }

    private var current: UInt64 = 0

    public init() {}

    public mutating func begin() -> Token {
        current &+= 1
        return Token(value: current)
    }

    public func shouldApply(_ token: Token) -> Bool {
        token.value == current
    }
}

/// A live power callback must reconcile the real global flag, not merely the
/// app's displayed state. Unknown read-back is treated conservatively.
public enum PowerCallbackPolicy {
    public static func requiresCorrectiveOff(policyRequiresOff: Bool,
                                             shownEnabled: Bool,
                                             activeWriteTarget: Bool?,
                                             observedGlobal: Bool?) -> Bool {
        guard policyRequiresOff else { return false }
        return shownEnabled || activeWriteTarget == true || observedGlobal != false
    }
}

public enum AuthorizationFailureDisposition: Equatable {
    case cancelled
    case denied
    case executionFailure
}

/// `osascript` reports AppleScript authorization errors through stderr while its
/// process status is usually just 1. Preserve the terminal user decisions.
public enum AuthorizationFailurePolicy {
    public static func classify(standardError: String) -> AuthorizationFailureDisposition {
        let message = standardError.lowercased()
        if message.contains("-128") || message.contains("user canceled") ||
            message.contains("user cancelled") {
            return .cancelled
        }
        if message.contains("-1743") || message.contains("not authorized") ||
            message.contains("not permitted") || message.contains("denied") {
            return .denied
        }
        return .executionFailure
    }
}

/// Decides which async replies are still worth applying.
///
/// A single in-flight flag isn't enough. Two reads can be outstanding at once
/// (popover open plus the 30-second tick) and reply out of order, and two writes
/// can do the same. Comparing observed values can't catch either, because a
/// repeated target looks identical and an on→off→on round trip ends where it
/// started. Monotonic counters can.
public struct StateSync: Equatable {

    public struct ReadToken: Equatable {
        let read: UInt64
        let mutations: UInt64
    }

    public struct MutationToken: Equatable {
        let mutation: UInt64
    }

    private var reads: UInt64 = 0
    private var mutations: UInt64 = 0

    public init() {}

    /// Issue a token for a read that's about to go out.
    public mutating func beginRead() -> ReadToken {
        reads += 1
        return ReadToken(read: reads, mutations: mutations)
    }

    /// Claim the next mutation slot — when a write starts, and when a reconciled
    /// read adopts a new state. Either supersedes everything already in flight.
    @discardableResult
    public mutating func beginMutation() -> MutationToken {
        mutations += 1
        return MutationToken(mutation: mutations)
    }

    /// A read applies only if it's the newest read issued *and* nothing has
    /// mutated the state since it went out.
    public func shouldApply(_ token: ReadToken) -> Bool {
        token.read == reads && token.mutations == mutations
    }

    /// A write completion applies only if it's still the newest mutation.
    public func shouldApply(_ token: MutationToken) -> Bool {
        token.mutation == mutations
    }
}
