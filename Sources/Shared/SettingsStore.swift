import Foundation

/// Persists SafetySettings in UserDefaults. Returns `.default` until the user
/// has saved at least once (so first launch uses sane defaults, not zeros).
public struct SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let lowBattery   = "lowBatteryThreshold"
        static let onlyCharging = "onlyWhileCharging"
        static let pauseThermal = "pauseOnHighThermal"
        static let seeded       = "settingsSeeded"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SafetySettings {
        guard defaults.bool(forKey: Key.seeded) else { return .default }
        return SafetySettings(
            lowBatteryThreshold: defaults.integer(forKey: Key.lowBattery),
            onlyWhileCharging: defaults.bool(forKey: Key.onlyCharging),
            pauseOnHighThermal: defaults.bool(forKey: Key.pauseThermal)
        )
    }

    public func save(_ settings: SafetySettings) {
        defaults.set(settings.lowBatteryThreshold, forKey: Key.lowBattery)
        defaults.set(settings.onlyWhileCharging, forKey: Key.onlyCharging)
        defaults.set(settings.pauseOnHighThermal, forKey: Key.pauseThermal)
        defaults.set(true, forKey: Key.seeded)
    }
}
