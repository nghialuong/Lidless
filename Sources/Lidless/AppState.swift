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

    private let helper = HelperManager()
    private let fallback = PowerManager()
    private let battery = BatteryMonitor()
    private var batteryTimer: Timer?
    private var heartbeatTimer: Timer?
    private let lowBatteryThreshold = 20

    init() {
        refreshHelperStatus()
        refreshState()
        refreshBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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

    func setEnabled(_ target: Bool) {
        if helperInstalled {
            helper.setKeepAwake(target) { [weak self] ok, err in
                guard let self else { return }
                if ok {
                    self.isEnabled = target
                    self.lastError = nil
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
                lastError = nil
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
            self?.helper.heartbeat()
        }
    }

    // MARK: Battery + safety guard

    func tick() {
        refreshBattery()
        let info = battery.read()
        if isEnabled, SafetyPolicy.shouldDisableForBattery(info, threshold: lowBatteryThreshold) {
            setEnabled(false)
            lastError = "Auto-disabled: battery \(info.percent)% on battery power."
        }
    }

    func refreshBattery() {
        let info = battery.read()
        batteryDescription = "\(info.source) · \(info.percent)%"
    }
}
