import SwiftUI
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isEnabled = false
    @Published var helperInstalled = false
    @Published var helperNeedsApproval = false
    @Published var batteryDescription = ""
    @Published var lastError: String?

    /// True when using the privileged helper; false when on the M1 admin-prompt fallback.
    @Published var usingHelper = false

    /// User-tunable safety preferences (persisted).
    @Published var settings: SafetySettings = .default

    private let helper = HelperManager()
    private let fallback = PowerManager()
    private let battery = BatteryMonitor()
    private let store = SettingsStore()
    private var batteryTimer: Timer?
    private var heartbeatTimer: Timer?

    init() {
        settings = store.load()
        refreshHelperStatus()
        refreshState()
        refreshBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Settings

    func updateSettings(_ new: SafetySettings) {
        settings = new
        store.save(new)
        evaluateSafety()
    }

    private func thermalSerious() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// Auto-disable keep-awake if current conditions violate the safety policy.
    func evaluateSafety() {
        guard isEnabled else { return }
        let info = battery.read()
        if let reason = SafetyEvaluator.reasonToDisable(battery: info,
                                                        thermalSerious: thermalSerious(),
                                                        settings: settings) {
            // Pass the reason through so it survives the async helper callback
            // (which would otherwise clear lastError on success).
            setEnabled(false, reason: reason)
        }
    }

    // MARK: Helper lifecycle

    func refreshHelperStatus() {
        helperInstalled = helper.isEnabled
        helperNeedsApproval = helper.requiresApproval
        usingHelper = helperInstalled
    }

    func installHelper() {
        do {
            try helper.register()
            refreshHelperStatus()
            if helper.requiresApproval {
                lastError = "Approve Lidless in System Settings ▸ Login Items."
                helper.openLoginItemsSettings()
            } else {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: State

    func refreshState() {
        if helperInstalled {
            helper.getState { [weak self] value in self?.isEnabled = value }
        } else {
            isEnabled = fallback.isSleepDisabled()
        }
    }

    func toggle() { setEnabled(!isEnabled) }

    /// Set keep-awake. `reason` is shown to the user on a successful change
    /// (used when an auto-pause disables it); nil clears any prior message.
    func setEnabled(_ target: Bool, reason: SafetyReason? = nil) {
        // Refuse to enable if it would immediately violate the safety policy.
        if target {
            let info = battery.read()
            if let blocker = SafetyEvaluator.reasonToDisable(battery: info,
                                                             thermalSerious: thermalSerious(),
                                                             settings: settings) {
                lastError = blocker.message
                return
            }
        }
        let resultMessage = reason?.message
        if helperInstalled {
            helper.setKeepAwake(target) { [weak self] ok, err in
                guard let self else { return }
                if ok {
                    self.isEnabled = target
                    self.lastError = resultMessage
                    self.manageHeartbeat()
                } else {
                    self.lastError = err
                    self.refreshState()
                }
            }
        } else {
            do {
                try fallback.setSleepDisabled(target)
                isEnabled = target
                lastError = resultMessage
            } catch {
                lastError = error.localizedDescription
                isEnabled = fallback.isSleepDisabled()
            }
        }
    }

    // MARK: Heartbeat (keeps the helper watchdog satisfied)

    private func manageHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard isEnabled, helperInstalled else { return }
        helper.heartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.helper.heartbeat() }
        }
    }

    // MARK: Battery + safety guard

    func tick() {
        refreshBattery()
        evaluateSafety()
    }

    func refreshBattery() {
        let info = battery.read()
        batteryDescription = "\(info.source) · \(info.percent)%"
    }
}
