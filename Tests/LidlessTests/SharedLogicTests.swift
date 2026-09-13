import XCTest

final class SharedLogicTests: XCTestCase {

    // MARK: PowerParsers.isSleepDisabled

    func testSleepDisabledTrue() {
        let out = """
        System-wide power settings:
         SleepDisabled        1
        Currently in use:
         standby              1
        """
        XCTAssertTrue(PowerParsers.isSleepDisabled(pmsetG: out))
    }

    func testSleepDisabledFalse() {
        let out = """
        System-wide power settings:
         SleepDisabled        0
        """
        XCTAssertFalse(PowerParsers.isSleepDisabled(pmsetG: out))
    }

    func testSleepDisabledMissing() {
        XCTAssertFalse(PowerParsers.isSleepDisabled(pmsetG: "Currently in use:\n standby 1"))
    }

    // MARK: PowerParsers.sleepDisabled — output that doesn't state the flag

    func testStrictSleepDisabledReadsTheFlag() {
        XCTAssertEqual(PowerParsers.sleepDisabled(pmsetG: " SleepDisabled        1"), true)
        XCTAssertEqual(PowerParsers.sleepDisabled(pmsetG: " SleepDisabled        0"), false)
    }

    /// `pmset` failing usually means empty stdout, which must not read as "off" —
    /// that would claim the Mac is free to sleep on the strength of no data.
    func testStrictSleepDisabledIsUnknownWhenOutputIsEmpty() {
        XCTAssertNil(PowerParsers.sleepDisabled(pmsetG: ""))
    }

    func testStrictSleepDisabledIsUnknownWhenKeyIsMissing() {
        XCTAssertNil(PowerParsers.sleepDisabled(pmsetG: "Currently in use:\n standby 1"))
    }

    func testStrictSleepDisabledIsUnknownWhenValueIsMalformed() {
        XCTAssertNil(PowerParsers.sleepDisabled(pmsetG: " SleepDisabled        yes"))
        XCTAssertNil(PowerParsers.sleepDisabled(pmsetG: " SleepDisabled"))
        XCTAssertNil(PowerParsers.sleepDisabled(pmsetG: " SleepDisabled        "))
    }

    /// Truncated output — the process died mid-write — states nothing.
    func testStrictSleepDisabledIsUnknownWhenOutputIsTruncated() {
        XCTAssertNil(PowerParsers.sleepDisabled(pmsetG: "System-wide power settings:\n Sleep"))
    }

    /// The lenient wrapper still exists for the helper's `Bool`-only XPC reply,
    /// and must keep collapsing unknown to false rather than changing behaviour.
    func testLenientFormCollapsesUnknownToFalse() {
        XCTAssertFalse(PowerParsers.isSleepDisabled(pmsetG: ""))
        XCTAssertFalse(PowerParsers.isSleepDisabled(pmsetG: " SleepDisabled        yes"))
        XCTAssertTrue(PowerParsers.isSleepDisabled(pmsetG: " SleepDisabled        1"))
    }

    // MARK: BatteryParsers

    func testBatteryOnAC() {
        let out = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=123)\t87%; charging; 0:42 remaining present: true"
        let info = BatteryParsers.parse(pmsetBatt: out)
        XCTAssertEqual(info.percent, 87)
        XCTAssertTrue(info.onAC)
        XCTAssertEqual(info.source, "AC")
    }

    func testBatteryOnBattery() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t19%; discharging; 1:05 remaining present: true"
        let info = BatteryParsers.parse(pmsetBatt: out)
        XCTAssertEqual(info.percent, 19)
        XCTAssertFalse(info.onAC)
        XCTAssertEqual(info.source, "Battery")
    }
    func testBatteryParserRejectsUnavailableMalformedAndContradictoryInput() {
        for output in [
            "",
            "Now drawing from 'AC Power'\n -InternalBattery-0\tunknown",
            "Now drawing from 'Battery Power'\n -InternalBattery-0\t101%",
            "Now drawing from 'UPS Power'\n -InternalBattery-0\t80%"
        ] {
            XCTAssertEqual(BatteryParsers.parse(pmsetBatt: output), .unknown)
        }
    }

    func testPowerSourceCrossCheckRequiresNotificationAndParserAgreement() {
        let ac = BatteryInfo(percent: 80, powerState: .ac)
        let battery = BatteryInfo(percent: 80, powerState: .battery)

        XCTAssertEqual(PowerSourceCrossCheck.reconcile(iokit: .ac, parsed: ac), ac)
        XCTAssertEqual(PowerSourceCrossCheck.reconcile(iokit: .battery, parsed: battery),
                       battery)
        XCTAssertEqual(PowerSourceCrossCheck.reconcile(iokit: .ac, parsed: battery),
                       .unknown)
        XCTAssertEqual(PowerSourceCrossCheck.reconcile(iokit: .battery, parsed: ac),
                       .unknown)
        XCTAssertEqual(PowerSourceCrossCheck.reconcile(iokit: nil, parsed: ac),
                       .unknown)
        XCTAssertEqual(PowerSourceCrossCheck.reconcile(iokit: .ac, parsed: .unknown),
                       .unknown)
    }


    // MARK: Watchdog

    func testWatchdogUsesMonotonicElapsedTime() {
        let second: UInt64 = 1_000_000_000
        XCTAssertTrue(
            Watchdog.shouldAutoRestore(
                lastHeartbeatUptime: 1_000 * second,
                nowUptime: 1_100 * second,
                timeout: 90
            )
        )
        XCTAssertFalse(
            Watchdog.shouldAutoRestore(
                lastHeartbeatUptime: 1_000 * second,
                nowUptime: 1_060 * second,
                timeout: 90
            )
        )
    }

    func testWatchdogDoesNotUnderflowIfClockSampleMovesBackward() {
        XCTAssertFalse(
            Watchdog.shouldAutoRestore(
                lastHeartbeatUptime: 2_000_000_000,
                nowUptime: 1_000_000_000,
                timeout: 0.5
            )
        )
    }

    // MARK: SafetyPolicy

    func testSafetyDisablesOnLowBattery() {
        let info = BatteryInfo(percent: 15, onAC: false)
        XCTAssertTrue(SafetyPolicy.shouldDisableForBattery(info, threshold: 20))
    }

    func testSafetyAllowsOnAC() {
        let info = BatteryInfo(percent: 5, onAC: true)
        XCTAssertFalse(SafetyPolicy.shouldDisableForBattery(info, threshold: 20))
    }

    func testSafetyAllowsAboveThreshold() {
        let info = BatteryInfo(percent: 80, onAC: false)
        XCTAssertFalse(SafetyPolicy.shouldDisableForBattery(info, threshold: 20))
    }

    // MARK: AutoOff

    func testAutoOffDeadlineIsStartPlusMinutes() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(AutoOff.deadline(from: start, minutes: 30),
                       Date(timeIntervalSince1970: 1000 + 1800))
    }

    func testAutoOffRemainingClampsToZero() {
        let deadline = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1100) // already past
        XCTAssertEqual(AutoOff.remaining(deadline: deadline, now: now), 0)
    }

    func testAutoOffRemainingCountsDown() {
        let deadline = Date(timeIntervalSince1970: 1100)
        let now = Date(timeIntervalSince1970: 1040)
        XCTAssertEqual(AutoOff.remaining(deadline: deadline, now: now), 60)
    }

    func testAutoOffExpiry() {
        let deadline = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(AutoOff.isExpired(deadline: deadline, now: deadline))
        XCTAssertTrue(AutoOff.isExpired(deadline: deadline, now: Date(timeIntervalSince1970: 1001)))
        XCTAssertFalse(AutoOff.isExpired(deadline: deadline, now: Date(timeIntervalSince1970: 999)))
    }

    func testAutoOffCountdownFormatting() {
        XCTAssertEqual(AutoOff.formatCountdown(30), "0:30")
        XCTAssertEqual(AutoOff.formatCountdown(582), "9:42")
        XCTAssertEqual(AutoOff.formatCountdown(3909), "1:05:09")
        XCTAssertEqual(AutoOff.formatCountdown(0), "0:00")
    }

    // MARK: AutoOff.request — "keep awake for N minutes" as one gesture

    /// The point of the change: asking for fifteen minutes of keep-awake turns
    /// keep-awake on. Before, it only armed a countdown for a switch the user
    /// still had to find and flip themselves.
    func testRequestEnablesKeepAwakeWhenItIsOff() {
        XCTAssertEqual(AutoOff.request(minutes: 15, isEnabled: false, autoModeOn: false),
                       .enableThenArmTimer(minutes: 15))
    }

    func testRequestJustArmsTimerWhenAlreadyOn() {
        XCTAssertEqual(AutoOff.request(minutes: 30, isEnabled: true, autoModeOn: false),
                       .armTimer(minutes: 30))
    }

    /// "No limit" removes the countdown. It must not also turn keep-awake off —
    /// that's a different request, and the master toggle already expresses it.
    func testRequestForNoLimitCancelsTimerWithoutDisabling() {
        XCTAssertEqual(AutoOff.request(minutes: 0, isEnabled: true, autoModeOn: false),
                       .cancelTimer)
        XCTAssertEqual(AutoOff.request(minutes: 0, isEnabled: false, autoModeOn: false),
                       .cancelTimer)
    }

    /// Auto mode owns activation; a countdown there would disarm the feature
    /// behind its back. Nothing happens, including no persisted change.
    func testRequestIsIgnoredInAutoModeWhateverElseIsTrue() {
        for minutes in [0, 15, 240] {
            for enabled in [true, false] {
                XCTAssertEqual(AutoOff.request(minutes: minutes, isEnabled: enabled, autoModeOn: true),
                               .ignoredInAutoMode,
                               "minutes=\(minutes) enabled=\(enabled)")
            }
        }
    }

    func testRequestCoversEveryPreset() {
        for minutes in AutoOff.presetMinutes {
            XCTAssertEqual(AutoOff.request(minutes: minutes, isEnabled: false, autoModeOn: false),
                           .enableThenArmTimer(minutes: minutes))
        }
    }

    func testDurationLabelNamesTheNoLimitCase() {
        XCTAssertEqual(AutoOff.durationLabel(minutes: 0), "No limit")
        XCTAssertEqual(AutoOff.durationLabel(minutes: 15), "15 min")
        XCTAssertEqual(AutoOff.durationLabel(minutes: 60), "1 hour")
    }

    func testAutoOffOptionLabels() {
        XCTAssertEqual(AutoOff.optionLabel(minutes: 15), "15 min")
        XCTAssertEqual(AutoOff.optionLabel(minutes: 30), "30 min")
        XCTAssertEqual(AutoOff.optionLabel(minutes: 60), "1 hour")
        XCTAssertEqual(AutoOff.optionLabel(minutes: 120), "2 hours")
        XCTAssertEqual(AutoOff.optionLabel(minutes: 240), "4 hours")
    }

    // MARK: SettingsStore onboarding flag

    func testOnboardingDefaultsToIncomplete() {
        let defaults = UserDefaults(suiteName: "lidless.test.onboarding.default")!
        defaults.removePersistentDomain(forName: "lidless.test.onboarding.default")
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.loadOnboardingComplete())
    }

    func testOnboardingCompletePersists() {
        let defaults = UserDefaults(suiteName: "lidless.test.onboarding.persist")!
        defaults.removePersistentDomain(forName: "lidless.test.onboarding.persist")
        let store = SettingsStore(defaults: defaults)
        store.saveOnboardingComplete(true)
        XCTAssertTrue(SettingsStore(defaults: defaults).loadOnboardingComplete())
    }
}
