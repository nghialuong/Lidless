import Foundation

/// User-tunable safety preferences for keep-awake.
public struct SafetySettings: Equatable {
    public var lowBatteryThreshold: Int
    public var onlyWhileCharging: Bool
    public var pauseOnHighThermal: Bool

    public static let `default` = SafetySettings(
        lowBatteryThreshold: 20,
        onlyWhileCharging: false,
        pauseOnHighThermal: true
    )

    public init(lowBatteryThreshold: Int, onlyWhileCharging: Bool, pauseOnHighThermal: Bool) {
        self.lowBatteryThreshold = lowBatteryThreshold
        self.onlyWhileCharging = onlyWhileCharging
        self.pauseOnHighThermal = pauseOnHighThermal
    }
}

/// Why keep-awake was (or should be) auto-disabled.
public enum SafetyReason: Equatable {
    case highThermal
    case notCharging
    case lowBattery(Int)

    public var message: String {
        switch self {
        case .highThermal:        return "Auto-paused: the Mac is running hot."
        case .notCharging:        return "Auto-paused: not on charger."
        case .lowBattery(let p):  return "Auto-paused: battery \(p)% on battery power."
        }
    }
}

/// Pure safety decision. No side effects, fully unit-testable.
public enum SafetyEvaluator {
    /// The reason keep-awake should be disabled given current conditions, or
    /// `nil` if it's safe to stay awake. Checked in priority order:
    /// thermal first (hardware protection), then charging policy, then battery.
    public static func reasonToDisable(battery: BatteryInfo,
                                       thermalSerious: Bool,
                                       settings: SafetySettings) -> SafetyReason? {
        if settings.pauseOnHighThermal && thermalSerious {
            return .highThermal
        }
        if settings.onlyWhileCharging && !battery.onAC {
            return .notCharging
        }
        if !battery.onAC && battery.percent <= settings.lowBatteryThreshold {
            return .lowBattery(battery.percent)
        }
        return nil
    }
}
