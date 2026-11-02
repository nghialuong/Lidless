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
        case .enabledOutside:  return L10n.tr("Sleep prevention was turned on outside Lidless.")
        case .disabledOutside: return L10n.tr("Sleep prevention was turned off outside Lidless.")
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

/// A write whose read-back hasn't confirmed it yet.
public struct PendingVerification: Equatable {
    public let target: Bool
    public init(target: Bool) { self.target = target }
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

    // MARK: Verifying a write

    public enum VerifyOutcome: Equatable {
        case verified
        /// The read-back failed. Keep the requested state — the write did report
        /// success — but don't present it as confirmed.
        case unverified
        /// The read-back contradicts the write.
        case mismatch(actual: Bool)
    }

    public static func verifyAfterSet(target: Bool, observed: Bool?) -> VerifyOutcome {
        guard let observed else { return .unverified }
        return observed == target ? .verified : .mismatch(actual: observed)
    }

    public enum PendingResolution: Equatable {
        case stillUnverified
        case confirmed
        case writeMismatch(actual: Bool)
    }

    /// A later read arriving while a write is still unconfirmed.
    ///
    /// This is deliberately *not* treated as external drift. We never confirmed
    /// our own write landed, so a disagreement is most honestly read as a write
    /// that didn't hold. An external actor could also have moved the flag in the
    /// meantime and the two are indistinguishable from here — but reporting the
    /// state we can see, without blaming a third party we can't observe, is the
    /// conservative reading.
    public static func resolve(_ pending: PendingVerification, observed: Bool?) -> PendingResolution {
        guard let observed else { return .stillUnverified }
        return observed == pending.target ? .confirmed : .writeMismatch(actual: observed)
    }

    /// Wording for a write we couldn't confirm. Both directions get a caveat:
    /// wrongly claiming keep-awake is on strands a build; wrongly claiming sleep
    /// is restored sends a running Mac into a bag.
    public static func unverifiedMessage(target: Bool) -> String {
        target
            ? L10n.tr("Couldn’t confirm keep-awake with the system — it may not hold when you close the lid.")
            : L10n.tr("Couldn’t confirm sleep was restored — your Mac may still stay awake.")
    }

    /// Wording for a write that demonstrably didn't hold. Kept distinct from
    /// `ExternalChange.message`, which attributes the change to someone else.
    public static func writeMismatchMessage(actual: Bool) -> String {
        actual
            ? L10n.tr("The change didn’t hold — the system reports keep-awake is on.")
            : L10n.tr("The change didn’t hold — the system reports keep-awake is off.")
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
