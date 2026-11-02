import Foundation

/// The lifecycle states of a privileged helper, named the same way everywhere
/// (popover, Settings, onboarding).
public enum HelperHealth: Equatable {
    case notInstalled
    case needsApproval
    case checking
    case healthy
    case unreachable
}

/// Owns the launch/reachability/repair lifecycle of the privileged helper.
///
/// The coordinator guarantees three invariants:
///
/// - **Never install or repair an absent/pending helper.** Only a registered
///   (`.enabled`) helper can be stale; anything else is the user's decision,
///   reached through `installHelper`.
/// - **The saved fingerprint means "this binary answers".** It is written only
///   after a healthy completed probe or a verified post-repair recovery —
///   never on a pending approval or a registration error. A failed repair
///   therefore leaves the record untouched, and the *next* launch retries.
/// - **One probe, one repair cycle at a time.** Every completion carries the
///   generation it was issued in; a repair (and its pending verification)
///   closes the cycle, so an older probe can neither clobber the post-repair
///   verdict nor trigger a second repair behind it. Registration is
///   snapshotted once per decision — once when a probe is dispatched, again
///   when its reply lands — so a registration that drops to pending/absent
///   while a probe is still in flight always wins over a stale reachable
///   reply, and always closes an open verification cycle itself rather than
///   leaving it to a probe that will now never run.
///
/// The coordinator holds no timers: after a successful registration it calls
/// `scheduleVerification` once and the host decides when launchd has had long
/// enough to spawn the fresh job, then probes again to verify recovery.
public final class HelperRepairCoordinator {
    public enum Registration: Equatable {
        case absent
        case pending
        case enabled
    }

    public enum RepairOutcome: Equatable {
        case registered(userInitiated: Bool)
        case needsApproval(userInitiated: Bool)
        case failed(userInitiated: Bool, error: String)
    }

    private enum ProbeKind {
        // Launch probe: a changed fingerprint plus an unreachable helper is
        // what authorizes an automatic repair.
        case launch(fingerprint: String, changed: Bool)
        // Post-repair probe: verifies recovery, never triggers another repair.
        case verifyRepair(fingerprint: String)
        // Popover opened, write failed, or an explicit check: informational.
        case refresh(fingerprint: String)
    }

    private let registration: () -> Registration
    private let savedFingerprint: () -> String
    private let saveFingerprint: (String) -> Void
    /// Asks the daemon whether it answers; fires once on the main queue.
    private let probe: (@escaping (Bool) -> Void) -> Void
    /// A registration succeeded and its verification probe is still owed;
    /// the repair cycle stays closed until that probe has run.
    private var verificationPending = false
    private let repair: (@escaping (Error?) -> Void) -> Void
    private let publish: (Registration, HelperHealth) -> Void
    private let scheduleVerification: () -> Void
    private let repairOutcome: (RepairOutcome) -> Void
    /// A repair recovered: the fresh daemon answered its verification probe.
    /// The host re-establishes watchdog ownership here (heartbeat or an
    /// explicit OFF), so no live `SleepDisabled=1` is left unowned.
    private let verifiedRecovery: () -> Void

    private var repairInFlight = false
    private var generation = 0
    private var probeInFlight = false

    public init(registration: @escaping () -> Registration,
                savedFingerprint: @escaping () -> String,
                saveFingerprint: @escaping (String) -> Void,
                probe: @escaping (@escaping (Bool) -> Void) -> Void,
                repair: @escaping (@escaping (Error?) -> Void) -> Void,
                publish: @escaping (Registration, HelperHealth) -> Void,
                scheduleVerification: @escaping () -> Void,
                repairOutcome: @escaping (RepairOutcome) -> Void,
                verifiedRecovery: @escaping () -> Void) {
        self.registration = registration
        self.savedFingerprint = savedFingerprint
        self.saveFingerprint = saveFingerprint
        self.probe = probe
        self.repair = repair
        self.publish = publish
        self.scheduleVerification = scheduleVerification
        self.repairOutcome = repairOutcome
        self.verifiedRecovery = verifiedRecovery
    }

    private static func health(for snapshot: Registration) -> HelperHealth {
        switch snapshot {
        case .absent: return .notInstalled
        case .pending: return .needsApproval
        case .enabled: return .checking
        }
    }

    // MARK: Entry points

    /// First launch of the app. Probes so the UI can show a dead helper, and
    /// automatically repairs one that a changed binary left unreachable.
    public func checkAtLaunch(fingerprint: String) {
        let snapshot = registration()
        guard snapshot == .enabled else {
            publish(snapshot, Self.health(for: snapshot))
            return
        }
        let changed = savedFingerprint() != fingerprint
        startProbe(.launch(fingerprint: fingerprint, changed: changed))
    }

    /// Re-check the current helper (popover opened, a write failed, or the
    /// helper just became usable). Never repairs on its own; the user decides
    /// from the Reinstall affordances the unreachable state carries. Dropped
    /// while a repair cycle is open — its verification probe owns the answer.
    public func checkNow(fingerprint: String) {
        guard !repairInFlight, !verificationPending else { return }
        probeIfEligible(.refresh(fingerprint: fingerprint))
    }

    /// The delayed post-repair verification probe. A healthy reply here is
    /// the "verified recovery" that finally persists the fingerprint and
    /// reports recovery to the host. Supersedes any refresh probe still in
    /// flight — that probe predates the recovery and must not swallow this.
    ///
    /// The cycle opened by `repair`'s success stays open across this entire
    /// call: `verificationPending` is cleared only once this probe lands a
    /// terminal result (`handleProbeResult`), never up front. Clearing it
    /// here — before the async reply — would let a `repair` or `checkNow`
    /// issued while this probe is still in flight slip past both guards and
    /// interleave with the verification it is supposed to wait behind.
    public func verifyRepair(fingerprint: String) {
        guard verificationPending, !repairInFlight else { return }
        // Any refresh probe still in flight predates the recovery: bump the
        // generation so its completion lands stale, and stop treating its
        // slot as occupied so this probe can start.
        generation += 1
        probeInFlight = false
        probeIfEligible(.verifyRepair(fingerprint: fingerprint))
    }

    /// Snapshot the registration once, as of this decision, and act on that
    /// snapshot alone. A non-enabled registration is a terminal result for
    /// whatever cycle is open: it clears `verificationPending` itself, because
    /// no probe is going to run to clear it for us. Leaving the flag set here
    /// — on the reasoning that only a probe's completion should close the
    /// cycle — is exactly how a registration that drops to pending/absent
    /// between the scheduled verification firing and its probe even starting
    /// would wedge every future `checkNow`/`repair` behind a verification that
    /// will now never run.
    private func probeIfEligible(_ kind: ProbeKind) {
        guard !repairInFlight else { return }
        let snapshot = registration()
        guard snapshot == .enabled else {
            verificationPending = false
            publish(snapshot, Self.health(for: snapshot))
            return
        }
        startProbe(kind)
    }
    /// Rebuild the launchd registration. Manual repairs may surface the
    /// approval step; automatic ones only record it (no surprise dialogs).
    public func repair(userInitiated: Bool) {
        let snapshot = registration()
        guard snapshot == .enabled else { return }
        // One repair owns the whole cycle: registration through its verified
        // verification probe. Nothing else may interleave.
        guard !repairInFlight, !verificationPending else { return }
        repairInFlight = true
        // Any probe still in flight belongs to the world this repair is about
        // to replace: bump the generation so its completion lands stale, and
        // stop treating its slot as occupied.
        generation += 1
        probeInFlight = false
        publish(.enabled, .checking)
        repair { [weak self] error in
            guard let self, self.repairInFlight else { return }
            self.repairInFlight = false
            if let error {
                // Leave the saved fingerprint alone: the next launch must see
                // this binary as still-unverified and retry the repair.
                // `repair` is unregister-then-register; a failure can land
                // with the registration actually absent or pending, not just
                // still-enabled-but-unreachable. Publish what's really there
                // instead of assuming the stale-helper case.
                let snapshot = self.registration()
                if snapshot == .enabled {
                    self.publish(snapshot, .unreachable)
                } else {
                    self.publish(snapshot, Self.health(for: snapshot))
                }
                self.repairOutcome(.failed(userInitiated: userInitiated,
                                           error: error.localizedDescription))
                return
            }
            let snapshot = self.registration()
            guard snapshot == .enabled else {
                self.publish(snapshot, Self.health(for: snapshot))
                self.repairOutcome(.needsApproval(userInitiated: userInitiated))
                return
            }
            // The registration itself succeeded. Report it now, before the
            // verification probe runs: a retained caller (e.g. a second
            // concurrent `repair` call collapsed into this one) must see this
            // outcome even though the cycle stays open until the probe lands.
            self.repairOutcome(.registered(userInitiated: userInitiated))
            self.verificationPending = true
            self.scheduleVerification()
        }
    }

    // MARK: Probe plumbing

    private func startProbe(_ kind: ProbeKind) {
        guard !probeInFlight else { return }
        probeInFlight = true
        publish(.enabled, .checking)
        let gen = generation
        probe { [weak self] reachable in
            guard let self, gen == self.generation else { return }
            self.probeInFlight = false
            self.handleProbeResult(reachable, kind: kind)
        }
    }

    /// Every probe completion rechecks the registration before acting on the
    /// reply, rather than trusting the snapshot `startProbe` saw when it was
    /// dispatched. Registration can change while the probe is in flight — the
    /// user revokes approval, the daemon gets unregistered from outside, an
    /// interleaved repair resolves to pending/absent — and a reachable reply
    /// about a helper that is no longer enabled is stale: it must not save a
    /// fingerprint or publish healthy/unreachable for a registration that no
    /// longer exists. Absent/pending wins over whatever the probe answered,
    /// with no auto-install triggered either way.
    private func handleProbeResult(_ reachable: Bool, kind: ProbeKind) {
        let currentRegistration = registration()
        if currentRegistration != .enabled {
            if case .verifyRepair = kind { verificationPending = false }
            publish(currentRegistration, Self.health(for: currentRegistration))
            return
        }
        switch kind {
        case .launch(let fingerprint, let changed):
            if reachable {
                saveFingerprint(fingerprint)
                publish(currentRegistration, .healthy)
            } else {
                publish(currentRegistration, .unreachable)
                if changed { repair(userInitiated: false) }
            }
        case .verifyRepair(let fingerprint):
            // The cycle `repair` opened closes here, on this probe's terminal
            // result — whichever way it lands — never before.
            verificationPending = false
            if reachable {
                saveFingerprint(fingerprint)
                publish(currentRegistration, .healthy)
                verifiedRecovery()
            } else {
                publish(currentRegistration, .unreachable)
            }
        case .refresh(let fingerprint):
            if reachable {
                saveFingerprint(fingerprint)
                publish(currentRegistration, .healthy)
            } else {
                publish(currentRegistration, .unreachable)
            }
        }
    }
}
