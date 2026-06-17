import Foundation

/// Reads battery level + power source by parsing `pmset -g batt`.
/// TODO (M2): switch to IOPowerSources for live notifications.
struct BatteryMonitor {
    func read() -> BatteryInfo {
        let out = Shell.capture("/usr/bin/pmset", ["-g", "batt"]) ?? ""
        return BatteryParsers.parse(pmsetBatt: out)
    }
}
