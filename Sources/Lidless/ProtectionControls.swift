import SwiftUI

/// The two protection controls, shown in the popover only in the Always mode:
/// the only mode where keep-awake can run on battery, so the only place where
/// these settings can actually take effect. Elsewhere they'd be dead controls,
/// and their values stay enforced regardless of visibility.
struct ProtectionControls: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Protection")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            SettingRow(title: "Pause when running hot") {
                Toggle("Pause when running hot", isOn: Binding(
                    get: { state.settings.pauseOnHighThermal },
                    set: { v in var s = state.settings; s.pauseOnHighThermal = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            LowBatteryCutoffRow()
        }
    }
}

/// Full-width low-battery cutoff slider (0–100%, snapping in 5% steps). `0` means
/// "Never" — the low-battery check is disabled entirely.
struct LowBatteryCutoffRow: View {
    @EnvironmentObject var state: AppState

    /// The value shown while dragging. Committing on every step would write
    /// UserDefaults — and run a reconcile that can reach the privileged
    /// helper — once per 5% of travel, so the commit waits for the drag to end.
    @State private var dragging: Double?

    private var threshold: Int { state.settings.lowBatteryThreshold }

    /// The committed value, or the in-flight one while a drag is in progress.
    private var shown: Int { Int((dragging ?? Double(threshold)).rounded()) }

    private var value: Binding<Double> {
        Binding(get: { dragging ?? Double(threshold) },
                set: { dragging = $0 })
    }

    /// Commit the dragged value once the drag ends, and only if it actually moved.
    private func commit(editing: Bool) {
        guard !editing, let value = dragging else { return }
        dragging = nil
        var updated = state.settings
        updated.lowBatteryThreshold = Int(value.rounded())
        guard updated != state.settings else { return }
        state.updateSettings(updated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Low-battery cutoff")
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(shown == 0 ? "Never" : "\(shown)%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: value,
                   in: 0...100,
                   step: 5,
                   label: { Text("Low-battery cutoff") },
                   minimumValueLabel: { Text("Never").font(.caption2).foregroundStyle(.secondary) },
                   maximumValueLabel: { Text("100%").font(.caption2).foregroundStyle(.secondary) },
                   onEditingChanged: commit)
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }
}
