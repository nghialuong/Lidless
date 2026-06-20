import SwiftUI

/// Shared horizontal inset so every row, divider, and the footer line up on the
/// same leading/trailing columns.
private let hInset: CGFloat = 20

/// The menu bar popover — "Minimal Quick Toggle".
///
/// Keeps only the essentials: the primary keep-awake switch, a compact status
/// strip, and the core safety controls. Everything secondary (helper setup,
/// launch at login, auto-off timer, GitHub) lives in the Settings window.
struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader()
                .padding(.horizontal, hInset)
                .padding(.top, 18)

            Text("Keep your Mac awake when the lid is closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, hInset)
                .padding(.top, 8)

            Divider()
                .padding(.horizontal, hInset)
                .padding(.top, 14)

            PrimaryToggleRow()
                .padding(.horizontal, hInset)

            Divider()
                .padding(.horizontal, hInset)

            StatusStrip()
                .padding(.horizontal, hInset)
                .padding(.vertical, 10)

            if let err = state.lastError {
                Label(err, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            Divider()
                .padding(.horizontal, hInset)

            SafetySection()
                .padding(.horizontal, hInset)
                .padding(.top, 12)

            Divider()
                .padding(.horizontal, hInset)
                .padding(.top, 12)

            FooterActions()
                .padding(.horizontal, hInset)
                .padding(.bottom, 14)
        }
        .frame(width: 360)
    }
}

// MARK: - Reusable row

/// A native settings-style row: leading label, flexible gap, trailing control
/// pinned to the shared right edge. Used for the primary toggle and every
/// safety row so all controls share one trailing column.
private struct SettingRow<Trailing: View>: View {
    let title: String
    var titleFont: Font = .callout
    var minHeight: CGFloat = 36
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
            Spacer(minLength: 16)
            trailing()
                .fixedSize()
        }
        .frame(minHeight: minHeight)
    }
}

// MARK: - Header

private struct PopoverHeader: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Lidless").font(.headline)
            Spacer()
            Text("v\(state.appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Primary control

/// The strongest row in the popover: the main keep-awake action.
private struct PrimaryToggleRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingRow(title: "Keep awake with lid closed",
                   titleFont: .body.weight(.semibold),
                   minHeight: 42) {
            Toggle("Keep awake with lid closed", isOn: Binding(
                get: { state.isEnabled },
                set: { _ in state.toggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .tint(.accentColor)
        }
    }
}

// MARK: - Status strip

/// Essential live status only: helper health + battery level.
private struct StatusStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: state.usingHelper ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(state.usingHelper ? .green : .orange)
                Text(state.usingHelper ? "Helper active" : "Helper inactive")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.usingHelper ? "Background helper active" : "Background helper inactive")

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: batterySymbol)
                Text("Battery \(state.batteryPercent)%")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Battery \(state.batteryPercent) percent\(state.batteryOnAC ? ", on power" : "")")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Closest native battery glyph for the current charge (names available on
    /// macOS 13+).
    private var batterySymbol: String {
        switch state.batteryPercent {
        case 88...:   return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default:      return "battery.0"
        }
    }
}

// MARK: - Safety

private struct SafetySection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Safety")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            SettingRow(title: "Only while charging") {
                Toggle("Only while charging", isOn: Binding(
                    get: { state.settings.onlyWhileCharging },
                    set: { v in var s = state.settings; s.onlyWhileCharging = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingRow(title: "Pause when running hot") {
                Toggle("Pause when running hot", isOn: Binding(
                    get: { state.settings.pauseOnHighThermal },
                    set: { v in var s = state.settings; s.pauseOnHighThermal = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingRow(title: "Low-battery cutoff") {
                HStack(spacing: 6) {
                    Text("\(state.settings.lowBatteryThreshold)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("Low-battery cutoff", value: Binding(
                        get: { state.settings.lowBatteryThreshold },
                        set: { v in var s = state.settings; s.lowBatteryThreshold = v; state.updateSettings(s) }
                    ), in: 5...50, step: 5)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Footer

private struct FooterActions: View {
    var body: some View {
        HStack {
            SettingsButton()
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Lidless", systemImage: "power")
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .frame(minHeight: 36)
    }
}

/// Opens the standard macOS Settings window. Uses the native `SettingsLink` on
/// macOS 14+, falling back to the AppKit action selector on macOS 13.
private struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut(",", modifiers: .command)
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
