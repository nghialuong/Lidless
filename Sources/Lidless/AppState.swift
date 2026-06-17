import SwiftUI
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var batteryDescription: String = ""
    @Published var lastError: String?

    private let power = PowerManager()
    private let battery = BatteryMonitor()
    private var timer: Timer?

    init() {
        isEnabled = power.isSleepDisabled()
        refreshBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
    }

    /// Flip the keep-awake state. Prompts for admin (M1 via pmset).
    func toggle() {
        let target = !isEnabled
        do {
            try power.setSleepDisabled(target)
            isEnabled = target
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            // Re-sync with the real flag in case the change partially applied.
            isEnabled = power.isSleepDisabled()
        }
    }

    func refreshBattery() {
        let b = battery.read()
        batteryDescription = "\(b.source) · \(b.percent)%"
    }
}
