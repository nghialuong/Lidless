import Foundation

struct BatteryInfo {
    let percent: Int
    let source: String   // "AC" or "Battery"
}

/// Reads battery level + power source by parsing `pmset -g batt`.
/// TODO (M2): switch to IOPowerSources for live notifications + the low-battery
/// safety guard (auto-clear SleepDisabled below a threshold).
struct BatteryMonitor {
    func read() -> BatteryInfo {
        let out = Shell.capture("/usr/bin/pmset", ["-g", "batt"]) ?? ""

        var percent = 0
        if let range = out.range(of: #"\d+%"#, options: .regularExpression) {
            let token = out[range].dropLast() // strip "%"
            percent = Int(token) ?? 0
        }

        let source = out.contains("AC Power") ? "AC" : "Battery"
        return BatteryInfo(percent: percent, source: source)
    }
}
