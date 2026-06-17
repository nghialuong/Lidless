import Foundation

/// Watchdog decision logic (pure, unit-testable).
public enum Watchdog {
    /// True when the app has gone quiet longer than `timeout`, so the helper
    /// should auto-restore normal sleep.
    public static func shouldAutoRestore(lastHeartbeat: Date, now: Date, timeout: TimeInterval) -> Bool {
        now.timeIntervalSince(lastHeartbeat) > timeout
    }
}

/// Battery safety policy (pure, unit-testable).
public enum SafetyPolicy {
    /// True when keep-awake should be auto-disabled to protect the battery:
    /// running on battery (not AC) at or below the threshold percent.
    public static func shouldDisableForBattery(_ info: BatteryInfo, threshold: Int) -> Bool {
        !info.onAC && info.percent <= threshold
    }
}
