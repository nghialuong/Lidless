import Foundation

/// Watchdog decision logic (pure, unit-testable). Monotonic uptime prevents a
/// wall-clock rollback from extending the period the helper can stay awake.
public enum Watchdog {
    public static func shouldAutoRestore(lastHeartbeatUptime: UInt64,
                                         nowUptime: UInt64,
                                         timeout: TimeInterval) -> Bool {
        guard nowUptime > lastHeartbeatUptime else { return false }
        let elapsed = TimeInterval(nowUptime - lastHeartbeatUptime) / 1_000_000_000
        return elapsed > timeout
    }
}

/// Battery safety policy (pure, unit-testable).
public enum SafetyPolicy {
    /// True when a known battery level is at/below the threshold. An unknown
    /// source also disables: a safety check cannot pass without readable input.
    public static func shouldDisableForBattery(_ info: BatteryInfo, threshold: Int) -> Bool {
        guard threshold > 0 else { return false }
        switch info.powerState {
        case .ac:      return false
        case .battery: return info.percent <= threshold
        case .unknown: return true
        }
    }
}
