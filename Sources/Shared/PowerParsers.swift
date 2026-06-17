import Foundation

/// Pure parsing helpers for `pmset` output. Kept free of side effects so they
/// can be unit-tested without touching real power management.
public enum PowerParsers {

    /// Parse `pmset -g` output and return whether the `SleepDisabled` flag is set.
    /// The relevant line looks like: ` SleepDisabled        1`
    public static func isSleepDisabled(pmsetG output: String) -> Bool {
        for raw in output.split(separator: "\n") {
            let line = String(raw).lowercased()
            guard line.contains("sleepdisabled") else { continue }
            let remainder = line
                .replacingOccurrences(of: "sleepdisabled", with: "")
                .trimmingCharacters(in: .whitespaces)
            return remainder == "1"
        }
        return false
    }
}

public struct BatteryInfo: Equatable {
    public let percent: Int
    public let onAC: Bool

    public init(percent: Int, onAC: Bool) {
        self.percent = percent
        self.onAC = onAC
    }

    public var source: String { onAC ? "AC" : "Battery" }
}

public enum BatteryParsers {
    /// Parse `pmset -g batt` output into a BatteryInfo.
    public static func parse(pmsetBatt output: String) -> BatteryInfo {
        var percent = 0
        if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
            percent = Int(output[range].dropLast()) ?? 0
        }
        let onAC = output.contains("AC Power")
        return BatteryInfo(percent: percent, onAC: onAC)
    }
}
