import XCTest

final class SafetyEvaluatorTests: XCTestCase {

    private let defaults = SafetySettings.default

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

    func testAutoEnableNeverActivatesOnBattery() {
        // Even at full charge, auto mode requires external power.
        XCTAssertFalse(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 100, onAC: false), thermalSerious: false, settings: defaults))
    }

    func testAutoEnableBlockedByThermalOnPower() {
        XCTAssertFalse(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 100, onAC: true), thermalSerious: true, settings: defaults))
    }

    func testAutoEnableBlockedByOnlyWhileChargingIsMootOnPower() {
        var s = defaults
        s.onlyWhileCharging = true
        XCTAssertTrue(AutoEnablePolicy.canActivate(
            battery: BatteryInfo(percent: 50, onAC: true), thermalSerious: false, settings: s))
    }

    // MARK: allUnmetReasons

    func testAllUnmetReasonsEmptyWhenSafeOnPower() {
        let info = BatteryInfo(percent: 80, onAC: true)
        XCTAssertTrue(SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: false, settings: defaults, requirePower: true).isEmpty)
    }

    func testAllUnmetReasonsListsPowerAndBatteryOffPower() {
        var s = defaults
        s.lowBatteryThreshold = 50
        let info = BatteryInfo(percent: 34, onAC: false)
        let reasons = SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: false, settings: s, requirePower: true)
        XCTAssertEqual(reasons, [.notOnPower, .lowBattery(34)])
    }

    func testAllUnmetReasonsDedupesPowerBullet() {
        // With requirePower and onlyWhileCharging both implying power, only the
        // power bullet appears — never both it and .notCharging.
        var s = defaults
        s.onlyWhileCharging = true
        s.lowBatteryThreshold = 0
        let info = BatteryInfo(percent: 90, onAC: false)
        let reasons = SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: false, settings: s, requirePower: true)
        XCTAssertEqual(reasons, [.notOnPower])
    }

    func testAllUnmetReasonsIncludesThermal() {
        let info = BatteryInfo(percent: 90, onAC: false)
        let reasons = SafetyEvaluator.allUnmetReasons(
            battery: info, thermalSerious: true, settings: defaults, requirePower: true)
        XCTAssertEqual(reasons.first, .highThermal)
        XCTAssertTrue(reasons.contains(.notOnPower))
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
