import Foundation

/// Pure parsing helpers for `pmset` output. Kept free of side effects so they
/// can be unit-tested without touching real power management.
public enum PowerParsers {

    /// Parse `pmset -g` output for the `SleepDisabled` flag. The relevant line
    /// looks like: ` SleepDisabled        1`
    ///
    /// Returns nil when the output doesn't actually state the flag — the key is
    /// absent, or its value is something other than `0`/`1`. Truncated or
    /// unexpected output must not read as "off": that's a claim the Mac is free
    /// to sleep, made from data that says nothing of the sort.
    public static func sleepDisabled(pmsetG output: String) -> Bool? {
        for raw in output.split(separator: "\n") {
            let line = String(raw).lowercased()
            guard line.contains("sleepdisabled") else { continue }
            let remainder = line
                .replacingOccurrences(of: "sleepdisabled", with: "")
                .trimmingCharacters(in: .whitespaces)
            switch remainder {
            case "1": return true
            case "0": return false
            default:  return nil
            }
        }
        return nil
    }

    /// Lenient form, kept for callers that have no way to act on "unknown" —
    /// the helper's XPC reply is a plain `Bool`. Prefer `sleepDisabled(pmsetG:)`.
    public static func isSleepDisabled(pmsetG output: String) -> Bool {
        sleepDisabled(pmsetG: output) ?? false
    }
}

public struct BatteryInfo: Equatable {
    public let percent: Int
    public let onAC: Bool

    public init(percent: Int, onAC: Bool) {
        self.percent = percent
        self.onAC = onAC
    }

    public var source: String { onAC ? L10n.tr("AC") : L10n.tr("Battery") }
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
