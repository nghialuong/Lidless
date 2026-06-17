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
        store.save(s)
        XCTAssertEqual(store.load(), s)
        d.removePersistentDomain(forName: suite)
    }
}
