import XCTest

final class SafetyEvaluatorTests: XCTestCase {

    private let defaults = SafetySettings.default

    /// Defaults with auto-enable mode switched on.
    private var auto: SafetySettings {
        var s = SafetySettings.default
        s.autoEnableWhenCharging = true
        return s
    }

    func testSafeWhenChargingAndCool() {
        let info = BatteryInfo(percent: 50, onAC: true)
        XCTAssertNil(SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: false, settings: defaults))
    }

    func testThermalTakesPriority() {
        let info = BatteryInfo(percent: 100, onAC: true)
        XCTAssertEqual(
            SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: true, settings: defaults),
            .highThermal
        )
    }

    func testThermalIgnoredWhenSettingOff() {
        var s = defaults
        s.pauseOnHighThermal = false
        let info = BatteryInfo(percent: 100, onAC: true)
        XCTAssertNil(SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: true, settings: s))
    }

    func testOnlyWhileChargingTriggersOnBattery() {
        var s = defaults
        s.onlyWhileCharging = true
        let info = BatteryInfo(percent: 90, onAC: false)
        XCTAssertEqual(
            SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: false, settings: s),
            .notCharging
        )
    }
    func testUnknownPowerFailsClosedWhenChargingOnlyIsEnabled() {
        var s = defaults
        s.onlyWhileCharging = true
        XCTAssertEqual(
            SafetyEvaluator.reasonToDisable(battery: .unknown,
                                            thermalSerious: false,
                                            settings: s),
            .powerUnavailable
        )
    }


    func testLowBatteryTriggers() {
        let info = BatteryInfo(percent: 15, onAC: false)
        XCTAssertEqual(
            SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: false, settings: defaults),
            .lowBattery(15)
        )
    }

    func testChargingOverridesLowBattery() {
        let info = BatteryInfo(percent: 5, onAC: true)
        XCTAssertNil(SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: false, settings: defaults))
    }

    func testReasonMessages() {
        XCTAssertEqual(SafetyReason.highThermal.message, "Auto-paused: the Mac is running hot.")
        XCTAssertEqual(SafetyReason.notCharging.message, "Auto-paused: not on charger.")
        XCTAssertEqual(SafetyReason.lowBattery(12).message, "Auto-paused: battery 12% on battery power.")
        XCTAssertEqual(SafetyReason.powerUnavailable.message,
                       "Auto-paused: power status is unavailable.")
    }

    // MARK: Low-battery cutoff = "Never" (0)

    func testThresholdZeroNeverTriggersLowBattery() {
        var s = defaults
        s.lowBatteryThreshold = 0
        let info = BatteryInfo(percent: 1, onAC: false)
        XCTAssertNil(SafetyEvaluator.reasonToDisable(battery: info, thermalSerious: false, settings: s))
    }

    // MARK: AutoEnablePolicy

    func testAutoEnableActivatesOnPowerWhenSafe() {
        XCTAssertTrue(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 5, onAC: true), thermalSerious: false, settings: defaults))
    }

    func testAutoEnableActivatesOnBatteryWhenBatteryChecksOff() {
        // Full charge, "Only while charging" off, no cutoff hit: auto mode adds
        // no power requirement of its own, so battery power alone can't block it.
        XCTAssertTrue(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 100, onAC: false), thermalSerious: false, settings: defaults))
    }

    func testAutoEnableBlockedOnBatteryWithOnlyWhileCharging() {
        var s = defaults
        s.onlyWhileCharging = true
        XCTAssertFalse(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 100, onAC: false), thermalSerious: false, settings: s))
    }

    func testAutoEnableBlockedByThermalOnPower() {
        XCTAssertFalse(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 100, onAC: true), thermalSerious: true, settings: defaults))
    }

    func testOnlyWhileChargingIsMootOnPower() {
        var s = defaults
        s.onlyWhileCharging = true
        XCTAssertTrue(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 50, onAC: true), thermalSerious: false, settings: s))
    }
    func testAutoEnableNeverActivatesWithUnknownPower() {
        XCTAssertFalse(AutoEnablePolicy.canActivate(
            battery: .unknown, thermalSerious: false, settings: defaults))
    }


    // MARK: AutoEnablePolicy.target — the state reconcile() acts on

    /// `auto` mode off: never our call to make, whatever else is true.
    func testTargetIsNilWhenAutoModeOff() {
        XCTAssertNil(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: false,
            battery: BatteryInfo(percent: 90, onAC: true),
            thermalSerious: false, settings: defaults))
    }

    func testTargetTurnsOnWhenArmedAndPluggedIn() {
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: false,
            battery: BatteryInfo(percent: 90, onAC: true),
            thermalSerious: false, settings: auto), true)
    }

    func testTargetStaysOnWhenUnpluggedWithoutChargingCheck() {
        // Auto mode adds no power requirement of its own: armed with the
        // battery checks off, being unplugged must not keep keep-awake off.
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: false,
            battery: BatteryInfo(percent: 90, onAC: false),
            thermalSerious: false, settings: auto), true)
    }

    func testTargetTurnsOffWhenUnpluggedWithOnlyWhileCharging() {
        var s = auto
        s.onlyWhileCharging = true
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: true,
            battery: BatteryInfo(percent: 90, onAC: false),
            thermalSerious: false, settings: s), false)
    }
    func testTargetTurnsOffWhenPowerBecomesUnknown() {
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: true,
            battery: .unknown,
            thermalSerious: false, settings: auto), false)
    }


    func testTargetTurnsOffWhenDisarmed() {
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: false, currentlyEnabled: true,
            battery: BatteryInfo(percent: 90, onAC: true),
            thermalSerious: false, settings: auto), false)
    }

    func testTargetTurnsOffWhenRunningHot() {
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: true,
            battery: BatteryInfo(percent: 90, onAC: true),
            thermalSerious: true, settings: auto), false)
    }

    /// The poll runs every 30s; a target equal to the live state must report
    /// "nothing to do" so we never rewrite the system flag on an idle tick.
    func testTargetIsNilWhenAlreadyCorrect() {
        XCTAssertNil(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: true,
            battery: BatteryInfo(percent: 90, onAC: true),
            thermalSerious: false, settings: auto))
        XCTAssertNil(AutoEnablePolicy.target(
            armed: false, currentlyEnabled: false,
            battery: BatteryInfo(percent: 90, onAC: true),
            thermalSerious: false, settings: auto))
        var s = auto
        s.onlyWhileCharging = true
        XCTAssertNil(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: false,
            battery: BatteryInfo(percent: 90, onAC: false),
            thermalSerious: false, settings: s))
    }

    /// Armed and plugged in, but the cutoff can't fire on power — so it stays on.
    func testTargetIgnoresCutoffWhileOnPower() {
        var s = auto
        s.lowBatteryThreshold = 95
        XCTAssertEqual(AutoEnablePolicy.target(
            armed: true, currentlyEnabled: false,
            battery: BatteryInfo(percent: 10, onAC: true),
            thermalSerious: false, settings: s), true)
    }

    // MARK: allUnmetReasons

    func testAllUnmetReasonsEmptyWhenSafeOnPower() {
        let info = BatteryInfo(percent: 80, onAC: true)
        XCTAssertTrue(SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: false, settings: defaults).isEmpty)
    }

    func testAllUnmetReasonsListsChargingAndBatteryOffPower() {
        var s = defaults
        s.onlyWhileCharging = true
        s.lowBatteryThreshold = 50
        let info = BatteryInfo(percent: 34, onAC: false)
        let reasons = SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: false, settings: s)
        XCTAssertEqual(reasons, [.notCharging, .lowBattery(34)])
    }

    /// `reasonToDisable` and `allUnmetReasons` share one low-battery predicate;
    /// this pins them together across the whole threshold boundary so a future
    /// edit to one can't quietly diverge from the other.
    func testLowBatteryAgreesAcrossBothEvaluators() {
        var s = defaults
        s.lowBatteryThreshold = 20
        for percent in [0, 1, 19, 20, 21, 100] {
            let info = BatteryInfo(percent: percent, onAC: false)
            let single = SafetyEvaluator.reasonToDisable(
                battery: info, thermalSerious: false, settings: s) == .lowBattery(percent)
            let listed = SafetyEvaluator.allUnmetReasons(
                battery: info, thermalSerious: false, settings: s).contains(.lowBattery(percent))
            XCTAssertEqual(single, listed, "disagreement at \(percent)%")
        }
    }

    func testAllUnmetReasonsIncludesThermal() {
        let info = BatteryInfo(percent: 90, onAC: false)
        let reasons = SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: true, settings: defaults)
        XCTAssertEqual(reasons.first, .highThermal)
    }

    // MARK: SettingsStore

    func testSettingsStoreDefaultsWhenUnseeded() {
        let suite = "test.lidless.unseeded"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        XCTAssertEqual(SettingsStore(defaults: d).load(), .default)
    }

    func testSettingsStoreRoundTrip() {
        let suite = "test.lidless.roundtrip"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: d)
        var s = SafetySettings.default
        s.onlyWhileCharging = true
        s.pauseOnHighThermal = false
        s.lowBatteryThreshold = 35
        s.autoEnableWhenCharging = true
        store.save(s)
        XCTAssertEqual(store.load(), s)
        d.removePersistentDomain(forName: suite)
    }

    func testArmedRoundTrip() {
        let suite = "test.lidless.armed"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: d)
        XCTAssertFalse(store.loadArmed())
        store.saveArmed(true)
        XCTAssertTrue(store.loadArmed())
        d.removePersistentDomain(forName: suite)
    }
}
