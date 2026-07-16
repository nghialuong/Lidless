import Foundation

/// User-tunable safety preferences for keep-awake.
public struct SafetySettings: Equatable {
    public var lowBatteryThreshold: Int
    public var onlyWhileCharging: Bool
    public var pauseOnHighThermal: Bool
    /// When true, keep-awake automatically (re-)activates while the Mac is on
    /// external power and every enabled safety check passes. See `AutoEnablePolicy`.
    public var autoEnableWhenCharging: Bool

    public static let `default` = SafetySettings(
        lowBatteryThreshold: 20,
        onlyWhileCharging: false,
        pauseOnHighThermal: true,
        autoEnableWhenCharging: false
    )

    public init(lowBatteryThreshold: Int,
                onlyWhileCharging: Bool,
                pauseOnHighThermal: Bool,
                autoEnableWhenCharging: Bool = false) {
        self.lowBatteryThreshold = lowBatteryThreshold
        self.onlyWhileCharging = onlyWhileCharging
        self.pauseOnHighThermal = pauseOnHighThermal
        self.autoEnableWhenCharging = autoEnableWhenCharging
    }
}

/// Why keep-awake was (or should be) auto-disabled.
public enum SafetyReason: Equatable {
    case highThermal
    case notCharging
    case lowBattery(Int)
    /// The Mac isn't on external power. Used by auto-enable mode, which requires
    /// external power regardless of the "Only while charging" preference.
    case notOnPower

    public var message: String {
        switch self {
        case .highThermal:        return "Auto-paused: the Mac is running hot."
        case .notCharging:        return "Auto-paused: not on charger."
        case .lowBattery(let p):  return "Auto-paused: battery \(p)% on battery power."
        case .notOnPower:         return "Auto-paused: not connected to power."
        }
    }

    /// Phrasing for when the user *tries to turn keep-awake on* but the policy
    /// won't allow it (vs. `message`, which describes a background auto-pause).
    public var blockedMessage: String {
        switch self {
        case .highThermal:        return "Your Mac is running hot, so keep-awake is paused. It'll be available again once the Mac cools down."
        case .notCharging:        return "\u{201C}Only while charging\u{201D} is on, so connect your Mac to power to keep it awake."
        case .lowBattery(let p):  return "Battery is at \(p)%. Charge above the low-battery cutoff to keep your Mac awake."
        case .notOnPower:         return "Connect your Mac to power to keep it awake."
        }
    }

    /// Short phrasing for the auto-mode warning bullet list (e.g. "Not connected
    /// to power"). Reflects the *current* unmet condition, not an auto-pause event.
    public var checkLabel: String {
        switch self {
        case .highThermal:        return "Running hot"
        case .notCharging:        return "Not on charger"
        case .lowBattery(let p):  return "Battery \(p)% is at or below the cutoff"
        case .notOnPower:         return "Not connected to power"
        }
    }
}

/// Pure safety decision. No side effects, fully unit-testable.
public enum SafetyEvaluator {
    /// The reason keep-awake should be disabled given current conditions, or
    /// `nil` if it's safe to stay awake. Checked in priority order:
    /// thermal first (hardware protection), then charging policy, then battery.
    ///
    /// A `lowBatteryThreshold` of 0 means "Never" — the low-battery check is
    /// disabled entirely.
    public static func reasonToDisable(battery: BatteryInfo,
                                       thermalSerious: Bool,
                                       settings: SafetySettings) -> SafetyReason? {
        if settings.pauseOnHighThermal && thermalSerious {
            return .highThermal
        }
        if settings.onlyWhileCharging && !battery.onAC {
            return .notCharging
        }
        if settings.lowBatteryThreshold > 0
            && !battery.onAC
            && battery.percent <= settings.lowBatteryThreshold {
            return .lowBattery(battery.percent)
        }
        return nil
    }

    /// Every currently-unmet check, for the auto-mode warning list — unlike
    /// `reasonToDisable`, which stops at the first. `requirePower` adds the
    /// external-power requirement that auto mode imposes on top of the user's
    /// enabled safety checks; when off power that power bullet subsumes the
    /// redundant "Only while charging" one so we never list both.
    public static func allUnmetReasons(battery: BatteryInfo,
                                       thermalSerious: Bool,
                                       settings: SafetySettings,
                                       requirePower: Bool) -> [SafetyReason] {
        var reasons: [SafetyReason] = []
        if settings.pauseOnHighThermal && thermalSerious {
            reasons.append(.highThermal)
        }
        if requirePower && !battery.onAC {
            reasons.append(.notOnPower)
        } else if settings.onlyWhileCharging && !battery.onAC {
            reasons.append(.notCharging)
        }
        if settings.lowBatteryThreshold > 0
            && !battery.onAC
            && battery.percent <= settings.lowBatteryThreshold {
            reasons.append(.lowBattery(battery.percent))
        }
        return reasons
    }
}

/// Pure decision for auto-enable mode ("Automatically enable when charging").
/// Keep-awake may activate only while on external power *and* every enabled
/// safety check passes. Requiring external power makes the low-battery check
/// moot (it only fires off power), matching "ignore the battery check on power".
public enum AutoEnablePolicy {
    public static func canActivate(battery: BatteryInfo,
                                   thermalSerious: Bool,
                                   settings: SafetySettings) -> Bool {
        guard battery.onAC else { return false }
        return SafetyEvaluator.reasonToDisable(battery: battery,
                                               thermalSerious: thermalSerious,
                                               settings: settings) == nil
    }
}
