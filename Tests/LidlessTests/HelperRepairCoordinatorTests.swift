import XCTest

/// The privileged helper's lifecycle: when a probe may auto-repair, when the
/// fingerprint may be persisted, and how a repair cycle stays serialized.
///
/// Each test drives `HelperRepairCoordinator` — the same object `AppState`
/// wires to the real XPC helper — turn by turn: probe dispatched, reply (or
/// timeout) lands, repair runs, verification probe follows. The coordinator
/// is retained by the fixture because its callbacks are `weak self` and each
/// async step must land on the live object, as in the app.
final class HelperRepairCoordinatorTests: XCTestCase {
    // Harness: records every call, replays scripted probe/repair results.
    private var registration: HelperRepairCoordinator.Registration = .enabled
    private var savedFingerprint = ""
    private var probeResult: Bool?
    private var repairError: Error?
    private var probeStarted = 0
    private var repairStarted = 0
    private var published: [HelperHealth] = []
    private var verificationScheduled = 0
    private var outcomes: [HelperRepairCoordinator.RepairOutcome] = []
    private var recoveryVerified = 0
    private var pendingProbe: ((Bool) -> Void)?
    private var pendingRepair: ((Error?) -> Void)?
    /// Strong reference so deferred completions land on a live coordinator.
    private var coordinator: HelperRepairCoordinator?

    private func makeCoordinator() -> HelperRepairCoordinator {
        let made = HelperRepairCoordinator(
            registration: { [unowned self] in self.registration },
            savedFingerprint: { [unowned self] in self.savedFingerprint },
            saveFingerprint: { [unowned self] in self.savedFingerprint = $0 },
            probe: { [unowned self] done in
                probeStarted += 1
                if let probeResult { done(probeResult) } else { pendingProbe = done }
            },
            repair: { [unowned self] done in
                repairStarted += 1
                if let repairError { done(repairError) } else { pendingRepair = done }
            },
            publish: { [unowned self] _, health in published.append(health) },
            scheduleVerification: { [unowned self] in verificationScheduled += 1 },
            repairOutcome: { [unowned self] in outcomes.append($0) },
            verifiedRecovery: { [unowned self] in recoveryVerified += 1 }
        )
        coordinator = made
        return made
    }

    // MARK: Absent and pending helpers are never touched

    /// A helper that isn't registered is never probed, never installed, never
    /// repaired — an absent helper must never be auto-installed.
    func testAbsentHelperIsNeverProbedOrRepaired() {
        registration = .absent
        makeCoordinator().checkAtLaunch(fingerprint: "5-abc")
        XCTAssertEqual(probeStarted, 0)
        XCTAssertEqual(repairStarted, 0)
        XCTAssertEqual(savedFingerprint, "")
        XCTAssertEqual(published, [.notInstalled])
    }

    /// Pending approval is a user decision, not a fault: no probe, no repair,
    /// and an explicit repair request does nothing either.
    func testPendingHelperIsNeverProbedAndExplicitRepairIsIgnored() {
        registration = .pending
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-abc")
        made.repair(userInitiated: true)
        XCTAssertEqual(probeStarted, 0)
        XCTAssertEqual(repairStarted, 0)
        XCTAssertEqual(published, [.needsApproval])
    }

    /// Regression: check-at-launch must bind one registration snapshot. A
    /// second read here could flip to enabled and incorrectly probe.
    func testCheckAtLaunchUsesSingleRegistrationSnapshot() {
        var reads = 0
        let made = HelperRepairCoordinator(
            registration: {
                reads += 1
                return reads == 1 ? .pending : .enabled
            },
            savedFingerprint: { "" },
            saveFingerprint: { _ in XCTFail("must not save fingerprint") },
            probe: { _ in XCTFail("must not probe") },
            repair: { _ in XCTFail("must not repair") },
            publish: { _, health in self.published.append(health) },
            scheduleVerification: { XCTFail("must not schedule verification") },
            repairOutcome: { _ in XCTFail("must not report repair outcome") },
            verifiedRecovery: { XCTFail("must not report recovery") }
        )
        coordinator = made
        made.checkAtLaunch(fingerprint: "5-abc")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(published, [.needsApproval])
    }

    /// Regression: probe gating must use one snapshot too; a second read could
    /// wrongly switch to enabled and dispatch a probe.
    func testCheckNowUsesSingleRegistrationSnapshot() {
        var reads = 0
        let made = HelperRepairCoordinator(
            registration: {
                reads += 1
                return reads == 1 ? .pending : .enabled
            },
            savedFingerprint: { "" },
            saveFingerprint: { _ in XCTFail("must not save fingerprint") },
            probe: { _ in XCTFail("must not probe") },
            repair: { _ in XCTFail("must not repair") },
            publish: { _, health in self.published.append(health) },
            scheduleVerification: { XCTFail("must not schedule verification") },
            repairOutcome: { _ in XCTFail("must not report repair outcome") },
            verifiedRecovery: { XCTFail("must not report recovery") }
        )
        coordinator = made
        made.checkNow(fingerprint: "5-abc")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(published, [.needsApproval])
    }

    /// Regression: probe result handling must bind one completion snapshot.
    /// A non-enabled completion snapshot must win over the probe reply.
    func testProbeResultUsesSingleRegistrationSnapshot() {
        var reads = 0
        var localProbe: ((Bool) -> Void)?
        var localSaved = ""
        var localPublished: [HelperHealth] = []

        let made = HelperRepairCoordinator(
            registration: {
                reads += 1
                switch reads {
                case 1: return .enabled  // probe dispatch gate
                case 2: return .pending  // probe completion snapshot
                default: return .enabled // would be stale extra read
                }
            },
            savedFingerprint: { "old" },
            saveFingerprint: { localSaved = $0 },
            probe: { done in localProbe = done },
            repair: { _ in XCTFail("must not repair") },
            publish: { _, health in localPublished.append(health) },
            scheduleVerification: { XCTFail("must not schedule verification") },
            repairOutcome: { _ in XCTFail("must not report repair outcome") },
            verifiedRecovery: { XCTFail("must not report recovery") }
        )
        coordinator = made

        made.checkNow(fingerprint: "new")
        localProbe?(true)

        XCTAssertEqual(localPublished, [.checking, .needsApproval])
        XCTAssertEqual(localSaved, "")
        XCTAssertEqual(reads, 2)
    }

    // MARK: Launch: fingerprint gates the automatic repair

    /// Same saved fingerprint, helper unreachable: surface it, don't repair —
    /// a probe of an unchanged binary has nothing to gain.
    func testUnreachableWithUnchangedFingerprintOnlyPublishes() {
        savedFingerprint = "5-same"
        makeCoordinator().checkAtLaunch(fingerprint: "5-same")
        pendingProbe?(false)
        XCTAssertEqual(repairStarted, 0)
        XCTAssertEqual(published, [.checking, .unreachable])
        XCTAssertEqual(savedFingerprint, "5-same")
    }

    /// Same *version*, different binary content: the fingerprint differs, the
    /// helper is unreachable, so the launch probe repairs automatically. The
    /// fingerprint is not saved before the repair proves itself.
    func testSameVersionBinaryChangeAutoRepairsWhenUnreachable() {
        savedFingerprint = "5-old"
        makeCoordinator().checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        XCTAssertEqual(repairStarted, 1)
        XCTAssertEqual(savedFingerprint, "5-old", "fingerprint must wait for verified recovery")
        XCTAssertTrue(outcomes.isEmpty, "automatic repair reports no failure yet")
    }

    /// A healthy probe is the one moment a fingerprint may be persisted.
    func testHealthyProbeSavesFingerprint() {
        savedFingerprint = "5-old"
        makeCoordinator().checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(true)
        XCTAssertEqual(savedFingerprint, "5-new")
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(repairStarted, 0, "healthy updates are left untouched")
    }

    // MARK: Repair outcomes

    /// A failed repair persists nothing, so the next launch still sees the
    /// binary as unverified and retries — failure must not suppress recovery.
    func testFailedRepairDoesNotSuppressNextStartupRecovery() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)              // unreachable → automatic repair
        pendingRepair?(TestError.broken)  // registration fails
        XCTAssertEqual(savedFingerprint, "5-old")
        XCTAssertEqual(published.last, .unreachable)

        // Next launch: same fingerprint, still unverified → repair again.
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        XCTAssertEqual(repairStarted, 2)
    }

    /// A registration that lands on pending approval is surfaced as such and
    /// saves nothing — the user still owes an approval, not a fingerprint.
    func testRepairPendingApprovalPublishesNeedsApprovalWithoutSaving() {
        savedFingerprint = "5-old"
        makeCoordinator().checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        registration = .pending
        pendingRepair?(nil)
        XCTAssertEqual(published.last, .needsApproval)
        XCTAssertEqual(savedFingerprint, "5-old")
        XCTAssertEqual(verificationScheduled, 0)
        XCTAssertEqual(outcomes, [.needsApproval(userInitiated: false)])
    }

    /// Regression: repair completion must bind one registration snapshot. When
    /// registration resolves to pending, a second read in the same completion
    /// must not be able to flip the published state.
    func testRepairCompletionUsesSingleRegistrationSnapshot() {
        var reads = 0
        var localRepair: ((Error?) -> Void)?
        var localPublished: [HelperHealth] = []
        var localOutcomes: [HelperRepairCoordinator.RepairOutcome] = []

        let made = HelperRepairCoordinator(
            registration: {
                reads += 1
                switch reads {
                case 1: return .enabled   // `repair` entry gate
                case 2: return .pending   // completion snapshot
                default: return .enabled  // would be a stale extra read
                }
            },
            savedFingerprint: { "" },
            saveFingerprint: { _ in XCTFail("must not save fingerprint") },
            probe: { _ in XCTFail("must not probe") },
            repair: { done in localRepair = done },
            publish: { _, health in localPublished.append(health) },
            scheduleVerification: { XCTFail("must not schedule verification") },
            repairOutcome: { localOutcomes.append($0) },
            verifiedRecovery: { XCTFail("must not report recovery") }
        )
        coordinator = made

        made.repair(userInitiated: true)
        localRepair?(nil)

        XCTAssertEqual(localPublished, [.checking, .needsApproval])
        XCTAssertEqual(localOutcomes, [.needsApproval(userInitiated: true)])
        XCTAssertEqual(reads, 2)
    }

    /// A repaired registration is not yet a recovered helper: verification
    /// must run, and only its healthy reply persists the fingerprint.
    func testFingerprintSavedOnlyAfterVerifiedRecovery() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)     // → repair
        pendingRepair?(nil)      // registered
        XCTAssertEqual(savedFingerprint, "5-old")
        XCTAssertEqual(verificationScheduled, 1)

        made.verifyRepair(fingerprint: "5-new")  // the delayed verification
        pendingProbe?(true)
        XCTAssertEqual(savedFingerprint, "5-new")
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(recoveryVerified, 1)
    }

    /// The verification probe finding the daemon still dead persists nothing,
    /// so the next launch retries — and the UI reports the state honestly.
    func testFailedVerificationDoesNotSaveFingerprint() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        pendingRepair?(nil)
        made.verifyRepair(fingerprint: "5-new")
        pendingProbe?(false)
        XCTAssertEqual(savedFingerprint, "5-old")
        XCTAssertEqual(published.last, .unreachable)
        XCTAssertEqual(recoveryVerified, 0)
    }

    // MARK: The repair cycle spans registration through verification

    /// A popover refresh arriving between register success and the scheduled
    /// verification must neither preempt the verification nor double-report
    /// recovery: the refresh is dropped, the verification decides, and
    /// `verifiedRecovery` fires exactly once.
    func testRefreshBetweenRegisterAndVerificationCannotSwallowVerification() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)   // → automatic repair
        pendingRepair?(nil)    // registered; verification now owed

        made.checkNow(fingerprint: "5-new")  // popover opens in the window
        XCTAssertEqual(probeStarted, 1, "refresh must be dropped, not probed")
        XCTAssertEqual(recoveryVerified, 0)

        made.verifyRepair(fingerprint: "5-new")
        pendingProbe?(true)
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(savedFingerprint, "5-new")
        XCTAssertEqual(recoveryVerified, 1, "recovery is reported exactly once")
    }

    /// A refresh probe already in flight when the verification fires predates
    /// the recovery; the verification supersedes it and decides alone.
    func testVerifyRepairSupersedesInFlightRefresh() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkNow(fingerprint: "5-new")  // refresh in flight…
        let staleRefresh = pendingProbe
        made.repair(userInitiated: true)     // …repair supersedes it
        pendingRepair?(nil)                  // registered
        made.verifyRepair(fingerprint: "5-new")  // verification supersedes again
        let verification = pendingProbe

        staleRefresh?(false)
        XCTAssertEqual(published.last, .checking, "stale refresh must not publish a verdict")
        XCTAssertEqual(recoveryVerified, 0)

        verification?(true)
        XCTAssertEqual(recoveryVerified, 1, "the verification decides alone")
        XCTAssertEqual(published.last, .healthy)
    }

    // MARK: Stale completions and serialization

    /// A probe still in flight when a repair begins lands stale — no state
    /// change, no second repair — and the post-repair verification decides.
    func testStaleProbeCompletionAfterRepairStartIsDiscarded() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkNow(fingerprint: "5-new")  // probe in flight…
        let staleProbe = pendingProbe
        made.repair(userInitiated: true)     // …then repair supersedes it
        staleProbe?(false)                   // stale completion arrives
        XCTAssertEqual(repairStarted, 1, "stale probe must not trigger a second repair")
        XCTAssertEqual(published.last, .checking, "stale probe must not publish a verdict")

        pendingRepair?(nil)
        made.verifyRepair(fingerprint: "5-new")
        pendingProbe?(true)
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(recoveryVerified, 1)
    }

    /// A second repair request during the verification window is ignored: the
    /// cycle from registration to verified recovery stays serialized.
    func testRepairDuringVerificationWindowIsIgnored() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        pendingRepair?(nil)
        made.repair(userInitiated: true)
        XCTAssertEqual(repairStarted, 1)
        made.verifyRepair(fingerprint: "5-new")
        pendingProbe?(true)
        XCTAssertEqual(recoveryVerified, 1)
    }

    /// Two repairs in a row collapse into one; the second caller must not
    /// interleave a second unregister/register behind the first.
    func testConcurrentRepairsAreSerialized() {
        let made = makeCoordinator()
        made.repair(userInitiated: true)
        made.repair(userInitiated: true)
        XCTAssertEqual(repairStarted, 1)
        pendingRepair?(nil)
        XCTAssertEqual(verificationScheduled, 1)
        XCTAssertEqual(outcomes.count, 1)
    }

    /// While a repair is running, popover-open probes stay out of the way
    /// instead of racing the verification probe.
    func testCheckNowDuringRepairIsDropped() {
        let made = makeCoordinator()
        made.repair(userInitiated: true)
        made.checkNow(fingerprint: "5-x")
        XCTAssertEqual(probeStarted, 0)
    }

    /// A repair request and a refresh request both arrive after `verifyRepair`
    /// has dispatched its probe but before that probe's reply lands. Neither
    /// may interrupt the open cycle: `verificationPending` must stay true for
    /// the whole in-flight window, not just until `verifyRepair` is called, so
    /// a stale clear can't let a second repair or a refresh probe interleave
    /// with the verification that still owns the answer.
    func testRepairAndRefreshDuringVerifyRepairProbeAreIgnored() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)   // → automatic repair
        pendingRepair?(nil)    // registered; verification now owed
        XCTAssertEqual(verificationScheduled, 1)

        made.verifyRepair(fingerprint: "5-new")  // verification probe dispatched…
        XCTAssertEqual(probeStarted, 2, "the verification probe is in flight")

        // …and, before it replies, both a manual repair and a refresh arrive.
        made.repair(userInitiated: true)
        XCTAssertEqual(repairStarted, 1, "a repair must not interrupt the open verification")
        made.checkNow(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 2, "a refresh must not interrupt the open verification either")

        pendingProbe?(true)  // the verification's own reply, finally
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(savedFingerprint, "5-new")
        XCTAssertEqual(recoveryVerified, 1, "the verification alone decides, exactly once")

        // The cycle is now closed: a fresh refresh is allowed again.
        made.checkNow(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 3)
    }

    /// Registration can drop to pending/absent between the scheduled
    /// verification firing (`scheduleVerification`'s callback) and
    /// `verifyRepair` even dispatching a probe — e.g. the user revoked
    /// approval, or the registration disappeared, in that window. That must
    /// be a terminal result: `verificationPending` has to clear itself here,
    /// because no probe is going to run to clear it, and every future
    /// `checkNow`/`repair` must not be locked out forever behind a
    /// verification that will now never happen.
    func testRegistrationBecomesPendingBeforeScheduledVerifyClearsCycle() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)   // → automatic repair
        pendingRepair?(nil)    // registered; verification now owed
        XCTAssertEqual(verificationScheduled, 1)

        // Before the scheduled verification even calls in, the registration
        // drops to pending (e.g. the user revoked approval).
        registration = .pending
        made.verifyRepair(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 1, "a non-enabled registration must not be probed")
        XCTAssertEqual(published.last, .needsApproval)
        XCTAssertEqual(savedFingerprint, "5-old", "nothing to verify, nothing to save")

        // The cycle must not be wedged: a later checkNow/repair works again
        // once the helper is usable.
        registration = .enabled
        made.checkNow(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 2, "checkNow must not be locked out by the abandoned verification")
        pendingProbe?(true)
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(savedFingerprint, "5-new")
    }

    /// Same window, but the registration disappears entirely rather than
    /// dropping to pending — the absent case must behave identically.
    func testRegistrationBecomesAbsentBeforeScheduledVerifyClearsCycle() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        pendingRepair?(nil)
        registration = .absent
        made.verifyRepair(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 1, "a non-enabled registration must not be probed")
        XCTAssertEqual(published.last, .notInstalled)
        XCTAssertEqual(savedFingerprint, "5-old")

        registration = .enabled
        made.repair(userInitiated: true)
        XCTAssertEqual(repairStarted, 2, "repair must not be locked out by the abandoned verification")
    }

    /// The registration can also drop to pending/absent *while the
    /// verification probe is already in flight* — after `verifyRepair`
    /// dispatched it, before its reply lands. A reachable reply must not be
    /// trusted once the registration that answered it is gone: no fingerprint
    /// is saved, no healthy/unreachable is published for a helper that no
    /// longer exists, and the absent/pending registration wins.
    func testRegistrationDisappearsDuringInFlightVerifyProbeReachable() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        pendingRepair?(nil)
        made.verifyRepair(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 2, "the verification probe is in flight")

        // The registration disappears while the probe is still outstanding.
        registration = .pending
        pendingProbe?(true)  // a reachable reply for a registration that's gone
        XCTAssertEqual(published.last, .needsApproval, "the stale reachable reply must not win")
        XCTAssertEqual(savedFingerprint, "5-old", "no fingerprint from a registration that's gone")
        XCTAssertEqual(recoveryVerified, 0, "no recovery for a registration that's gone")

        // The cycle must not be wedged afterward.
        registration = .enabled
        made.checkNow(fingerprint: "5-new")
        XCTAssertEqual(probeStarted, 3)
        pendingProbe?(true)
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(savedFingerprint, "5-new")
    }

    /// Same in-flight window, but the probe's reply is a failure rather than a
    /// success. The absent/pending registration still wins over an
    /// unreachable verdict, and the cycle still closes rather than wedging.
    func testRegistrationDisappearsDuringInFlightVerifyProbeFailure() {
        savedFingerprint = "5-old"
        let made = makeCoordinator()
        made.checkAtLaunch(fingerprint: "5-new")
        pendingProbe?(false)
        pendingRepair?(nil)
        made.verifyRepair(fingerprint: "5-new")

        registration = .absent
        pendingProbe?(false)
        XCTAssertEqual(published.last, .notInstalled, "the absent registration must win over unreachable")
        XCTAssertEqual(savedFingerprint, "5-old")
        XCTAssertEqual(recoveryVerified, 0)

        // Usable again afterward: checkAtLaunch-style recovery still works.
        registration = .enabled
        made.repair(userInitiated: true)
        XCTAssertEqual(repairStarted, 2, "repair must not be locked out by the abandoned verification")
        pendingRepair?(nil)
        made.verifyRepair(fingerprint: "5-new")
        pendingProbe?(true)
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(savedFingerprint, "5-new")
        XCTAssertEqual(recoveryVerified, 1)
    }

    // MARK: Refresh probes

    /// A popover-open probe of a healthy helper re-confirms and persists the
    /// fingerprint (idempotent when unchanged).
    func testHealthyRefreshSavesFingerprint() {
        savedFingerprint = "5-new"
        makeCoordinator().checkNow(fingerprint: "5-new")
        pendingProbe?(true)
        XCTAssertEqual(savedFingerprint, "5-new")
        XCTAssertEqual(published.last, .healthy)
        XCTAssertEqual(repairStarted, 0)
    }

    /// A refresh probe never repairs on its own — the unreachable state comes
    /// with explicit Reinstall affordances for the user to decide.
    func testUnreachableRefreshDoesNotAutoRepair() {
        savedFingerprint = "5-new"
        makeCoordinator().checkNow(fingerprint: "5-new")
        pendingProbe?(false)
        XCTAssertEqual(repairStarted, 0)
        XCTAssertEqual(published.last, .unreachable)
    }

    // MARK: Fingerprint identity

    /// The fingerprint is content identity: a rebuilt binary at the same
    /// version must differ, a version bump must differ, and an unreadable
    /// binary degrades to the build number.
    func testFingerprintIsContentIdentity() {
        let data = Data("helper-binary".utf8)
        XCTAssertEqual(HelperFingerprint.compute(build: "5", binary: data),
                       HelperFingerprint.compute(build: "5", binary: data),
                       "identical content at the same build must match")
        XCTAssertNotEqual(HelperFingerprint.compute(build: "5", binary: data),
                          HelperFingerprint.compute(build: "5", binary: Data("other".utf8)),
                          "same version, changed binary must differ")
        XCTAssertNotEqual(HelperFingerprint.compute(build: "5", binary: data),
                          HelperFingerprint.compute(build: "6", binary: data),
                          "a build bump must differ")
        XCTAssertEqual(HelperFingerprint.compute(build: "5", binary: nil), "5")
    }

    private enum TestError: Error { case broken }
}
