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

    // MARK: Watchdog

    func testWatchdogFiresAfterTimeout() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1100) // 100s later
        XCTAssertTrue(Watchdog.shouldAutoRestore(lastHeartbeat: last, now: now, timeout: 90))
    }

    func testWatchdogQuietWithinTimeout() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1060) // 60s later
        XCTAssertFalse(Watchdog.shouldAutoRestore(lastHeartbeat: last, now: now, timeout: 90))
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
}
