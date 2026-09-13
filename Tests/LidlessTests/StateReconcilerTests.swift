import XCTest

/// Covers the decision logic behind issue #21: keeping the UI in step with the
/// real `SleepDisabled` flag without ever asserting a state we haven't read.
final class StateReconcilerTests: XCTestCase {

    // MARK: Reconciling a fresh read

    func testExternalEnableIsAdoptedAsDrift() {
        XCTAssertEqual(StateReconciler.reconcile(shown: false, hasBaseline: true, observed: true),
                       .drift(.enabledOutside))
        XCTAssertTrue(ExternalChange.enabledOutside.nowEnabled)
    }

    func testExternalDisableInvalidatesStaleEnabledState() {
        XCTAssertEqual(StateReconciler.reconcile(shown: true, hasBaseline: true, observed: false),
                       .drift(.disabledOutside))
        XCTAssertFalse(ExternalChange.disabledOutside.nowEnabled)
    }

    func testUnknownReadKeepsShownEnabledState() {
        XCTAssertEqual(StateReconciler.reconcile(shown: true, hasBaseline: true, observed: nil), .unknown)
    }

    func testUnknownReadKeepsShownDisabledState() {
        XCTAssertEqual(StateReconciler.reconcile(shown: false, hasBaseline: true, observed: nil), .unknown)
    }

    /// Guards idempotence: a steady-state poll must report nothing adoptable, or
    /// every pass would re-arm the auto-off timer and restart the heartbeat.
    func testAgreeingReadIsInSyncEvenWithoutBaseline() {
        XCTAssertEqual(StateReconciler.reconcile(shown: true, hasBaseline: true, observed: true), .inSync)
        XCTAssertEqual(StateReconciler.reconcile(shown: false, hasBaseline: true, observed: false), .inSync)
        XCTAssertEqual(StateReconciler.reconcile(shown: false, hasBaseline: false, observed: false), .inSync)
    }

    func testFirstDifferingObservationAdoptsWithoutWarning() {
        XCTAssertEqual(StateReconciler.reconcile(shown: false, hasBaseline: false, observed: true),
                       .adopt(enabled: true))
    }

    func testFirstObservationUnknownStaysUnknown() {
        XCTAssertEqual(StateReconciler.reconcile(shown: false, hasBaseline: false, observed: nil), .unknown)
    }

    /// End to end across the two pure layers: unreadable `pmset` output must
    /// reach the reconciler as "unknown" and leave the shown state alone, rather
    /// than parsing into a confident "off" that flips the toggle.
    func testUnreadablePmsetOutputReconcilesToUnknown() {
        for output in ["", "Currently in use:\n standby 1", " SleepDisabled        yes"] {
            let observed = PowerParsers.sleepDisabled(pmsetG: output)
            XCTAssertNil(observed, "\(output.debugDescription) states nothing about the flag")
            XCTAssertEqual(StateReconciler.reconcile(shown: true, hasBaseline: true, observed: observed),
                           .unknown)
        }
    }

    // MARK: Stale replies — reads

    func testFreshReadApplies() {
        var sync = StateSync()
        let token = sync.beginRead()
        XCTAssertTrue(sync.shouldApply(token))
    }

    func testNewerReadInvalidatesTheOlderReply() {
        var sync = StateSync()
        let first = sync.beginRead()
        let second = sync.beginRead()
        XCTAssertFalse(sync.shouldApply(first), "an out-of-order reply must not win")
        XCTAssertTrue(sync.shouldApply(second))
    }

    func testMutationInvalidatesAnInFlightRead() {
        var sync = StateSync()
        let read = sync.beginRead()
        sync.beginMutation()
        XCTAssertFalse(sync.shouldApply(read))
    }

    /// Two mutations put the value back where it started; comparing observed
    /// values could never tell that anything happened, but the counter can.
    func testABARoundTripStillInvalidatesTheRead() {
        var sync = StateSync()
        let read = sync.beginRead()
        sync.beginMutation()
        sync.beginMutation()
        XCTAssertFalse(sync.shouldApply(read))
    }

    // MARK: Stale replies — writes

    func testStaleWriteCompletionIsRejected() {
        var sync = StateSync()
        let first = sync.beginMutation()
        let second = sync.beginMutation()
        XCTAssertFalse(sync.shouldApply(first))
        XCTAssertTrue(sync.shouldApply(second))
    }

    func testOutOfOrderWriteRepliesApplyOnlyTheLatest() {
        var sync = StateSync()
        let older = sync.beginMutation()
        let newer = sync.beginMutation()
        // The older write replies last; it must still lose.
        XCTAssertTrue(sync.shouldApply(newer))
        XCTAssertFalse(sync.shouldApply(older))
    }

    /// Both writes ask for the same target, so only the counter distinguishes
    /// them — the payload is identical.
    func testDuplicateTargetWritesStillInvalidateTheOlder() {
        var sync = StateSync()
        let first = sync.beginMutation()
        let second = sync.beginMutation()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(sync.shouldApply(first))
    }

    func testABAWriteSequenceRejectsTheFirstCompletion() {
        var sync = StateSync()
        let on = sync.beginMutation()
        sync.beginMutation()               // off
        sync.beginMutation()               // on again
        XCTAssertFalse(sync.shouldApply(on))
    }

    func testAdoptionInvalidatesAnInFlightWrite() {
        var sync = StateSync()
        let write = sync.beginMutation()
        sync.beginMutation()               // a reconciled read adopting a new state
        XCTAssertFalse(sync.shouldApply(write))
    }

    // MARK: Notice lifecycle

    /// The regression test for external-enable followed by a low-battery pause:
    /// the pause must not erase the notice that explains where the state came from.
    func testOnlyUserActionClearsTheExternalNotice() {
        XCTAssertTrue(StateReconciler.clearsExternalNotice(.user))
        XCTAssertFalse(StateReconciler.clearsExternalNotice(.safety))
        XCTAssertFalse(StateReconciler.clearsExternalNotice(.autoOff))
    }

    func testDriftMessagesDescribeTheEventNotTheResultingState() {
        // Must stay true after a safety pause flips the state straight back, so
        // it may not promise anything about what the Mac is doing now.
        for change in [ExternalChange.enabledOutside, .disabledOutside] {
            XCTAssertTrue(change.message.contains("outside Lidless"))
            XCTAssertFalse(change.message.contains("will"))
        }
    }

    // MARK: Verified writes

    func testMismatchRetriesThenMatchingReadBackSucceeds() {
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: 1,
                                         writeSucceeded: true,
                                         observed: true),
            .retry(after: 0.15, failure: .mismatch(actual: true))
        )
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: 2,
                                         writeSucceeded: true,
                                         observed: false),
            .verified
        )
    }

    func testCommandErrorRetriesEvenWhenReadBackMatches() {
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: 1,
                                         writeSucceeded: false,
                                         observed: false),
            .retry(after: 0.15, failure: .writeFailed)
        )
    }

    func testTerminalMismatchAndReadFailureAreBounded() {
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: VerifiedWritePolicy.maximumAttempts,
                                         writeSucceeded: true,
                                         observed: true),
            .terminal(failure: .mismatch(actual: true))
        )
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: VerifiedWritePolicy.maximumAttempts,
                                         writeSucceeded: true,
                                         observed: nil),
            .terminal(failure: .readFailed)
        )
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: VerifiedWritePolicy.maximumAttempts,
                                         writeSucceeded: false,
                                         observed: nil),
            .terminal(failure: .writeFailed)
        )
        XCTAssertEqual(VerifiedWritePolicy.retryDelays, [0.15, 0.35])
        XCTAssertEqual(VerifiedWritePolicy.retryDelays.count,
                       VerifiedWritePolicy.maximumAttempts - 1)
        XCTAssertLessThan(VerifiedWritePolicy.retryDelays.reduce(0, +), 1)
    }

    func testMidSequenceReadFailureRetries() {
        XCTAssertEqual(
            VerifiedWritePolicy.decision(target: false,
                                         attempt: 1,
                                         writeSucceeded: true,
                                         observed: nil),
            .retry(after: 0.15, failure: .readFailed)
        )
    }

    func testEveryUncertainEnableRequiresCorrectiveOffForAllObservedStates() {
        for observed in [Optional<Bool>.none, false, true] {
            XCTAssertTrue(
                VerifiedWritePolicy.requiresFailClosedCorrection(
                    target: true,
                    writeSucceeded: false,
                    observed: observed
                ),
                "observed=\(String(describing: observed))"
            )
        }
        XCTAssertTrue(
            VerifiedWritePolicy.requiresFailClosedCorrection(
                target: true,
                writeSucceeded: true,
                observed: nil
            )
        )
        XCTAssertFalse(
            VerifiedWritePolicy.requiresFailClosedCorrection(
                target: true,
                writeSucceeded: true,
                observed: true
            )
        )
        XCTAssertFalse(
            VerifiedWritePolicy.requiresFailClosedCorrection(
                target: false,
                writeSucceeded: false,
                observed: true
            )
        )
    }

    func testHelperFailureBookkeepingKeepsFailedRestoresRetryable() {
        XCTAssertFalse(
            HelperSafetyPolicy.keepAwakeAfterFailedWrite(
                requestedEnable: true,
                restoreSucceeded: true
            )
        )
        XCTAssertTrue(
            HelperSafetyPolicy.keepAwakeAfterFailedWrite(
                requestedEnable: true,
                restoreSucceeded: false
            )
        )
        XCTAssertTrue(
            HelperSafetyPolicy.keepAwakeAfterFailedWrite(
                requestedEnable: false,
                restoreSucceeded: true
            )
        )
    }

    func testWatchdogClearsBookkeepingOnlyAfterVerifiedRestore() {
        XCTAssertTrue(
            HelperSafetyPolicy.keepAwakeAfterWatchdogAttempt(
                previous: true,
                restoreSucceeded: false
            )
        )
        XCTAssertFalse(
            HelperSafetyPolicy.keepAwakeAfterWatchdogAttempt(
                previous: true,
                restoreSucceeded: true
            )
        )
    }

    func testPowerCallbackUsesObservedGlobalFlagWhenDisplayIsOff() {
        XCTAssertTrue(
            PowerCallbackPolicy.requiresCorrectiveOff(
                policyRequiresOff: true,
                shownEnabled: false,
                activeWriteTarget: nil,
                observedGlobal: true
            )
        )
        XCTAssertTrue(
            PowerCallbackPolicy.requiresCorrectiveOff(
                policyRequiresOff: true,
                shownEnabled: false,
                activeWriteTarget: nil,
                observedGlobal: nil
            )
        )
        XCTAssertFalse(
            PowerCallbackPolicy.requiresCorrectiveOff(
                policyRequiresOff: true,
                shownEnabled: false,
                activeWriteTarget: nil,
                observedGlobal: false
            )
        )
    }

    func testPowerCallbackOffSupersedesAnActiveEnable() {
        XCTAssertTrue(
            PowerCallbackPolicy.requiresCorrectiveOff(
                policyRequiresOff: true,
                shownEnabled: false,
                activeWriteTarget: true,
                observedGlobal: false
            )
        )
    }

    func testPowerCallbackDoesNotInventOffWhenPolicyAllowsOn() {
        XCTAssertFalse(
            PowerCallbackPolicy.requiresCorrectiveOff(
                policyRequiresOff: false,
                shownEnabled: true,
                activeWriteTarget: true,
                observedGlobal: nil
            )
        )
    }

    func testStalePowerGenerationCannotApplyAfterNewerUnplugSample() {
        var generations = PowerSampleGeneration()
        let staleAC = generations.begin()
        let unplug = generations.begin()

        XCTAssertFalse(generations.shouldApply(staleAC))
        XCTAssertTrue(generations.shouldApply(unplug))
    }

    func testChargingGatedEnableRequiresSubscriptionAndSignedHelper() {
        XCTAssertTrue(
            PowerNotificationPolicy.allowsChargingGatedEnable(
                subscriptionActive: true,
                signedHelperAvailable: true
            )
        )
        XCTAssertFalse(
            PowerNotificationPolicy.allowsChargingGatedEnable(
                subscriptionActive: false,
                signedHelperAvailable: true
            )
        )
        XCTAssertFalse(
            PowerNotificationPolicy.allowsChargingGatedEnable(
                subscriptionActive: true,
                signedHelperAvailable: false
            )
        )
    }

    func testHelperOrderingSkipsAndCancelsOnlyStaleEnables() {
        XCTAssertFalse(
            HelperOperationPolicy.shouldStart(requestedEnable: true,
                                              isCurrent: false)
        )
        XCTAssertTrue(
            HelperOperationPolicy.shouldCancel(requestedEnable: true,
                                               isCurrent: false)
        )
        XCTAssertTrue(
            HelperOperationPolicy.shouldStart(requestedEnable: false,
                                              isCurrent: false)
        )
        XCTAssertFalse(
            HelperOperationPolicy.shouldCancel(requestedEnable: false,
                                               isCurrent: false)
        )
    }

    func testHelperRestartTreatsUnknownAndOnAsOwned() {
        XCTAssertTrue(HelperRecoveryPolicy.potentiallyKeepsAwake(observed: nil))
        XCTAssertTrue(HelperRecoveryPolicy.potentiallyKeepsAwake(observed: true))
        XCTAssertFalse(HelperRecoveryPolicy.potentiallyKeepsAwake(observed: false))
    }

    func testHelperCoalescesPendingOffAndAlwaysSelectsItFirst() {
        XCTAssertEqual(
            HelperQueuePolicy.admission(
                requestedEnable: false,
                hasPendingEnable: true,
                hasPendingOff: true
            ),
            .coalescePendingOff
        )
        XCTAssertEqual(
            HelperQueuePolicy.nextTarget(
                hasPendingEnable: true,
                hasPendingOff: true
            ),
            false
        )
    }

    func testFallbackCancelsOnlyStaleEnableSoOffRemainsFinal() {
        XCTAssertTrue(
            AuthorizationMutationPolicy.shouldCancel(
                requestedEnable: true,
                isCurrent: false
            )
        )
        XCTAssertFalse(
            AuthorizationMutationPolicy.shouldCancel(
                requestedEnable: false,
                isCurrent: false
            )
        )
    }

    func testRetryAndAbsoluteDeadlineBudgetAreMechanicallyBounded() {
        XCTAssertEqual(VerifiedWritePolicy.retryDelay(afterAttempt: 1,
                                                      remaining: 0.16),
                       0.15)
        XCTAssertNil(VerifiedWritePolicy.retryDelay(afterAttempt: 1,
                                                    remaining: 0.15))
        XCTAssertNil(VerifiedWritePolicy.retryDelay(
            afterAttempt: VerifiedWritePolicy.maximumAttempts,
            remaining: 10
        ))

        let fullCriticalPath = SafetyTiming.readTimeout
            + SafetyTiming.helperReplyTimeout
            + SafetyTiming.readTimeout
        XCTAssertEqual(SafetyTiming.maximumUnplugResponse, fullCriticalPath)
        XCTAssertLessThanOrEqual(SafetyTiming.maximumUnplugResponse, 4.25)
        XCTAssertLessThan(SafetyTiming.helperEnablePhaseTimeout,
                          SafetyTiming.helperOperationTimeout)

        let deadline = ProcessDeadline(uptimeNanoseconds: 2_000_000_000)
        XCTAssertEqual(deadline.remaining(at: 1_250_000_000), 0.75)
        XCTAssertEqual(deadline.reserving(0.25).uptimeNanoseconds,
                       1_750_000_000)
        XCTAssertEqual(deadline.remaining(at: 2_000_000_000), 0)
    }

    func testAuthorizationCancellationAndDenialAreTerminallyClassified() {
        XCTAssertEqual(
            AuthorizationFailurePolicy.classify(
                standardError: "execution error: User canceled. (-128)"
            ),
            .cancelled
        )
        XCTAssertEqual(
            AuthorizationFailurePolicy.classify(
                standardError: "Not authorized to send Apple events. (-1743)"
            ),
            .denied
        )
        XCTAssertEqual(
            AuthorizationFailurePolicy.classify(standardError: "launch failed"),
            .executionFailure
        )
    }
}
