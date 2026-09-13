import Foundation

/// User-tunable safety preferences for keep-awake.
public struct SafetySettings: Equatable {
    public var lowBatteryThreshold: Int
    public var onlyWhileCharging: Bool
    public var pauseOnHighThermal: Bool
    /// When true, keep-awake automatically activates while `armed` and every
    /// enabled safety check passes. On battery, only the enabled checks
    /// ("Only while charging", low-battery cutoff, thermal) pause it.
    /// See `AutoEnablePolicy`.
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
    /// Power-source data is unavailable, malformed, stale, or contradictory.
    case powerUnavailable
    case lowBattery(Int)

    public var message: String {
        switch self {
        case .highThermal:          return "Auto-paused: the Mac is running hot."
        case .notCharging:          return "Auto-paused: not on charger."
        case .lowBattery(let p):    return "Auto-paused: battery \(p)% on battery power."
        case .powerUnavailable:     return "Auto-paused: power status is unavailable."
        }
    }

    /// Phrasing for when the user *tries to turn keep-awake on* but the policy
    /// won't allow it (vs. `message`, which describes a background auto-pause).
    public var blockedMessage: String {
        switch self {
        case .highThermal:          return "Your Mac is running hot, so keep-awake is paused. It'll be available again once the Mac cools down."
        case .notCharging:          return "\u{201C}Only while charging\u{201D} is on, so connect your Mac to power to keep it awake."
        case .lowBattery(let p):    return "Battery is at \(p)%. Charge above the low-battery cutoff to keep your Mac awake."
        case .powerUnavailable:     return "Lidless can’t verify the current power source, so keep-awake is paused."
        }
    }

    /// Short phrasing for the auto-mode warning bullet list. Reflects the
    /// *current* unmet condition, not an auto-pause event.
    public var checkLabel: String {
        switch self {
        case .highThermal:          return "Running hot"
        case .notCharging:          return "Not on charger"
        case .lowBattery(let p):    return "Battery \(p)% is at or below the cutoff"
        case .powerUnavailable:     return "Power status unavailable"
        }
    }
}

/// One sample of everything a safety decision reads from the world.
///
/// Exists so a decision and the write it authorises can be judged against the
/// same conditions. Sampling twice — once to decide, once to check on the way
/// out — puts a seam between them that the world can change across, and a write
/// refused at that seam is a write that never claimed a mutation, so it
/// supersedes nothing and leaves whatever it was correcting in force.
public struct SafetySnapshot: Equatable {
    public let battery: BatteryInfo
    public let thermalSerious: Bool

    public init(battery: BatteryInfo, thermalSerious: Bool) {
        self.battery = battery
        self.thermalSerious = thermalSerious
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
        if battery.powerState == .unknown,
           settings.onlyWhileCharging || settings.lowBatteryThreshold > 0 {
            return .powerUnavailable
        }
        if settings.onlyWhileCharging && battery.powerState != .ac {
            return .notCharging
        }
        return lowBatteryReason(battery: battery, settings: settings)
    }

    /// The low-battery check, shared by `reasonToDisable` and `allUnmetReasons`
    /// so the two can't drift. Only fires off power, and a threshold of 0
    /// ("Never") disables it entirely.
    private static func lowBatteryReason(battery: BatteryInfo,
                                         settings: SafetySettings) -> SafetyReason? {
        guard settings.lowBatteryThreshold > 0,
              battery.powerState == .battery,
              battery.percent <= settings.lowBatteryThreshold else { return nil }
        return .lowBattery(battery.percent)
    }

    /// Every currently-unmet check, for the auto-mode warning list — unlike
    /// `reasonToDisable`, which stops at the first.
    public static func allUnmetReasons(battery: BatteryInfo,
                                       thermalSerious: Bool,
                                       settings: SafetySettings) -> [SafetyReason] {
        var reasons: [SafetyReason] = []
        if settings.pauseOnHighThermal && thermalSerious {
            reasons.append(.highThermal)
        }
        if battery.powerState == .unknown {
            if settings.onlyWhileCharging || settings.lowBatteryThreshold > 0 {
                reasons.append(.powerUnavailable)
            }
            return reasons
        }
        if settings.onlyWhileCharging && battery.powerState != .ac {
            reasons.append(.notCharging)
        }
        if let lowBattery = lowBatteryReason(battery: battery, settings: settings) {
            reasons.append(lowBattery)
        }
        return reasons
    }
}

/// Pure decision for auto-enable mode ("Automatically enable when charging").
/// Auto mode owns turning keep-awake on; whether it *stays* on in a given
/// condition is decided solely by the user's enabled safety checks
/// ("Only while charging", low-battery cutoff, thermal). Auto mode itself adds
/// no power requirement of its own.
public enum AutoEnablePolicy {
    public static func canActivate(battery: BatteryInfo,
                                   thermalSerious: Bool,
                                   settings: SafetySettings) -> Bool {
        SafetyEvaluator.reasonToDisable(battery: battery,
                                        thermalSerious: thermalSerious,
                                        settings: settings) == nil
    }

    /// The live keep-awake state auto mode wants, or `nil` when there's nothing
    /// to do — auto mode is off, or the state already matches. Returning `nil`
    /// for "already correct" keeps the caller from writing the system flag on
    /// every poll tick.
    ///
    /// `currentlyEnabled` must be the *effective* state — see `effectiveState`.
    /// Comparing against the shown state instead is how an intent expressed
    /// while a write is still travelling gets silently dropped.
    public static func target(armed: Bool,
                              currentlyEnabled: Bool,
                              battery: BatteryInfo,
                              thermalSerious: Bool,
                              settings: SafetySettings) -> Bool? {
        guard settings.autoEnableWhenCharging else { return nil }
        let shouldBeOn = armed && canActivate(battery: battery,
                                              thermalSerious: thermalSerious,
                                              settings: settings)
        return shouldBeOn == currentlyEnabled ? nil : shouldBeOn
    }

    /// Where keep-awake is *heading*: the target of a write still in flight, or
    /// the shown state when nothing is outstanding.
    ///
    /// Every decision has to be taken against this rather than against the shown
    /// state. A dispatched write hasn't moved `isEnabled` yet — that happens in
    /// its reply — so a user changing their mind mid-flight would otherwise be
    /// compared against a state the system has already left, conclude nothing
    /// needs doing, and let the earlier write land unopposed.
    public static func effectiveState(pendingTarget: Bool?, live: Bool) -> Bool {
        pendingTarget ?? live
    }

    /// Leaving auto mode while a write is still travelling: the state to settle
    /// on, which the caller must then actually write.
    ///
    /// Manual mode inherits where the system was heading, so the starting point
    /// is the outstanding target. But "on" is only honest while it's still
    /// allowed — conditions can have lapsed since that write went out — and
    /// settling on "off" is also what keeps the write unconditional. A write of
    /// `true` can be refused by the safety check before it claims a mutation,
    /// which would leave the superseded auto reply free to land after all; a
    /// write of `false` is never refused.
    public static func handoffToManual(pendingTarget: Bool,
                                       conditions: SafetySnapshot,
                                       settings: SafetySettings) -> Bool {
        guard pendingTarget else { return false }
        return writeIsPermitted(target: true, conditions: conditions, settings: settings)
    }

    /// Whether the safety check on the way out of `setEnabled` will let a write
    /// of `target` through, given the conditions it checks against.
    ///
    /// This mirrors that check exactly, so a caller can guarantee its write won't
    /// be refused by handing the same snapshot to both. Two properties follow,
    /// and the auto path depends on each:
    ///
    /// - A `false` target is never refused. That is what lets a corrective "off"
    ///   supersede a pending "on" under any conditions at all.
    /// - A `true` target decided from a snapshot is still permitted under that
    ///   same snapshot, by construction. Re-sampling instead would reopen the
    ///   seam this is here to close.
    public static func writeIsPermitted(target: Bool,
                                        conditions: SafetySnapshot,
                                        settings: SafetySettings) -> Bool {
        guard target else { return true }
        return SafetyEvaluator.reasonToDisable(battery: conditions.battery,
                                               thermalSerious: conditions.thermalSerious,
                                               settings: settings) == nil
    }
}
