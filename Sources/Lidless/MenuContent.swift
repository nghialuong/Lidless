import SwiftUI

/// The menu bar popover — "Minimal Quick Toggle".
///
/// Keeps only the essentials: the primary keep-awake switch, a compact status
/// strip, and the core safety controls. Everything secondary (helper setup,
/// launch at login, auto-off timer, GitHub) lives in the Settings window.
struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                PopoverHeader()
                Text("Keep your Mac awake when the lid is closed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrimaryToggleRow()

            Divider()

            StatusStrip()

            if let err = state.lastError {
                Label(err, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            SafetySection()

            Divider()

            FooterActions()
        }
        .padding(20)
        .frame(width: 360)
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Primary control

/// The strongest row in the popover: the main keep-awake action.
private struct PrimaryToggleRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Toggle(isOn: Binding(
            get: { state.isEnabled },
            set: { _ in state.toggle() }
        )) {
            Text("Keep awake with lid closed")
                .font(.body.weight(.medium))
        }
        .toggleStyle(.switch)
        .controlSize(.large)
        .tint(.accentColor)
    }
}

// MARK: - Status strip

/// Essential live status only: helper health + battery level.
private struct StatusStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Image(systemName: state.usingHelper ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(state.usingHelper ? .green : .orange)
                Text(state.usingHelper ? "Helper active" : "Helper inactive")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.usingHelper ? "Background helper active" : "Background helper inactive")

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: batterySymbol)
                    .foregroundStyle(.secondary)
                Text("Battery \(state.batteryPercent)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Battery \(state.batteryPercent) percent\(state.batteryOnAC ? ", on power" : "")")
        }
        .font(.callout)
    }

    /// Closest native battery glyph for the current charge (names available on
    /// macOS 13+).
    private var batterySymbol: String {
        switch state.batteryPercent {
        case 88...:  return "battery.100"
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Safety")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Only while charging", isOn: Binding(
                get: { state.settings.onlyWhileCharging },
                set: { v in var s = state.settings; s.onlyWhileCharging = v; state.updateSettings(s) }
            ))
            .toggleStyle(.switch)

            Toggle("Pause when running hot", isOn: Binding(
                get: { state.settings.pauseOnHighThermal },
                set: { v in var s = state.settings; s.pauseOnHighThermal = v; state.updateSettings(s) }
            ))
            .toggleStyle(.switch)

            Stepper(value: Binding(
                get: { state.settings.lowBatteryThreshold },
                set: { v in var s = state.settings; s.lowBatteryThreshold = v; state.updateSettings(s) }
            ), in: 5...50, step: 5) {
                HStack {
                    Text("Low-battery cutoff")
                    Spacer()
                    Text("\(state.settings.lowBatteryThreshold)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

/// Opens the standard macOS Settings window. Uses the native `SettingsLink` on
/// macOS 14+, falling back to the AppKit action selector on macOS 13.
private struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
