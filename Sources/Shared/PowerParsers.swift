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

public enum PowerSourceState: String, Equatable {
    case ac
    case battery
    case unknown
}

public struct BatteryInfo: Equatable {
    public let percent: Int
    public let powerState: PowerSourceState

    public init(percent: Int, powerState: PowerSourceState) {
        self.percent = percent
        self.powerState = powerState
    }

    public init(percent: Int, onAC: Bool) {
        self.init(percent: percent, powerState: onAC ? .ac : .battery)
    }

    public static let unknown = BatteryInfo(percent: 0, powerState: .unknown)

    public var onAC: Bool { powerState == .ac }

    public var source: String {
        switch powerState {
        case .ac:      return "AC"
        case .battery: return "Battery"
        case .unknown: return "Unknown"
        }
    }
}

/// Combines the notification provider with the independently parsed `pmset`
/// sample. Only agreement is authoritative.
public enum PowerSourceCrossCheck {
    public static func reconcile(iokit: PowerSourceState?,
                                 parsed: BatteryInfo) -> BatteryInfo {
        guard let iokit,
              iokit != .unknown,
              parsed.powerState == iokit else {
            return .unknown
        }
        return parsed
    }
}

public enum BatteryParsers {
    /// Parse `pmset -g batt` output. Anything missing or contradictory remains
    /// explicitly unknown so safety decisions never mistake parse failure for AC.
    public static func parse(pmsetBatt output: String) -> BatteryInfo {
        guard let header = output.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return .unknown
        }

        let powerState: PowerSourceState
        switch header.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Now drawing from 'AC Power'":
            powerState = .ac
        case "Now drawing from 'Battery Power'":
            powerState = .battery
        default:
            return .unknown
        }

        guard let range = output.range(of: #"\d{1,3}%"#, options: .regularExpression),
              let percent = Int(output[range].dropLast()),
              (0...100).contains(percent) else {
            return .unknown
        }
        return BatteryInfo(percent: percent, powerState: powerState)
    }
}
