import Foundation

/// Persists SafetySettings in UserDefaults. Returns `.default` until the user
/// has saved at least once (so first launch uses sane defaults, not zeros).
public struct SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let lowBattery   = "lowBatteryThreshold"
        static let onlyCharging = "onlyWhileCharging"
        static let pauseThermal = "pauseOnHighThermal"
        static let autoEnable   = "autoEnableWhenCharging"
        static let armed        = "keepAwakeArmed"
        static let seeded       = "settingsSeeded"
        static let autoOff      = "autoOffMinutes"
        static let onboarded    = "onboardingComplete"
        static let resumeOnboarding = "resumeOnboarding"
        static let helperBuild  = "lastRegisteredHelperBuild"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SafetySettings {
        guard defaults.bool(forKey: Key.seeded) else { return .default }
        return SafetySettings(
            lowBatteryThreshold: defaults.integer(forKey: Key.lowBattery),
            onlyWhileCharging: defaults.bool(forKey: Key.onlyCharging),
            pauseOnHighThermal: defaults.bool(forKey: Key.pauseThermal),
            autoEnableWhenCharging: defaults.bool(forKey: Key.autoEnable)
        )
    }

    public func save(_ settings: SafetySettings) {
        defaults.set(settings.lowBatteryThreshold, forKey: Key.lowBattery)
        defaults.set(settings.onlyWhileCharging, forKey: Key.onlyCharging)
        defaults.set(settings.pauseOnHighThermal, forKey: Key.pauseThermal)
        defaults.set(settings.autoEnableWhenCharging, forKey: Key.autoEnable)
        defaults.set(true, forKey: Key.seeded)
    }

    /// The master-toggle intent in auto mode: whether the user wants keep-awake
    /// armed (the live state is then gated by power + safety). Defaults to false.
    public func loadArmed() -> Bool {
        defaults.bool(forKey: Key.armed)
    }

    public func saveArmed(_ armed: Bool) {
        defaults.set(armed, forKey: Key.armed)
    }

    /// Auto-off duration in minutes (`0` = no auto-off). Defaults to 0.
    public func loadAutoOffMinutes() -> Int {
        defaults.integer(forKey: Key.autoOff)
    }

    public func saveAutoOffMinutes(_ minutes: Int) {
        defaults.set(minutes, forKey: Key.autoOff)
    }

    /// Whether the user has been through first-run onboarding. Defaults to false.
    public func loadOnboardingComplete() -> Bool {
        defaults.bool(forKey: Key.onboarded)
    }

    public func saveOnboardingComplete(_ complete: Bool) {
        defaults.set(complete, forKey: Key.onboarded)
    }

    /// Whether onboarding should be re-shown on the next launch — set when the app
    /// relaunches itself mid-onboarding (after the helper is enabled) so the flow
    /// resumes instead of being lost. Defaults to false.
    public func loadResumeOnboarding() -> Bool {
        defaults.bool(forKey: Key.resumeOnboarding)
    }

    public func saveResumeOnboarding(_ resume: Bool) {
        defaults.set(resume, forKey: Key.resumeOnboarding)
    }

    /// The app build (`CFBundleVersion`) for which the privileged helper was last
    /// (re-)registered. Used to refresh the launchd registration after an update,
    /// so the daemon keeps launching with the new binary's requirement. Empty
    /// until the first registration.
    public func loadLastHelperBuild() -> String {
        defaults.string(forKey: Key.helperBuild) ?? ""
    }

    public func saveLastHelperBuild(_ build: String) {
        defaults.set(build, forKey: Key.helperBuild)
    }
}
