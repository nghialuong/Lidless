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

            Text(L10n.tr("Keep your Mac awake when the lid is closed."))
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

            KeepAwakeDurationRow()
                .padding(.horizontal, hInset)

            if !state.autoWarningReasons.isEmpty {
                AutoDisabledWarning(reasons: state.autoWarningReasons)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            Divider()
                .padding(.horizontal, hInset)

            StatusStrip()
                .padding(.horizontal, hInset)
                .padding(.vertical, 10)

            // Three disjoint slots, strongest first: something changed the flag
            // behind our back, we couldn't confirm our own change, and the
            // ordinary error/safety note.
            if let notice = state.externalNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

            if let notice = state.verificationNotice {
                Label(notice, systemImage: "questionmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, hInset)
                    .padding(.bottom, 10)
            }

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

            AutomaticSection()
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
        // The popover is the moment the user actually looks at the toggle, so
        // it's the moment it most needs to be true.
        .onAppear { state.refreshState() }
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
            Text(L10n.tr("Lidless")).font(.headline)
            Spacer()
            Text(L10n.format("v%@", state.appVersion))
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
        SettingRow(title: L10n.tr("Keep awake with lid closed"),
                   titleFont: .body.weight(.semibold),
                   minHeight: 42) {
            Toggle(L10n.tr("Keep awake with lid closed"), isOn: Binding(
                get: { state.masterToggleOn },
                set: { state.setMasterToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .tint(.accentColor)
        }
    }
}

// MARK: - Keep-awake duration

/// "Keep awake for 15 minutes" as a single gesture: picking a duration turns
/// keep-awake on and starts the countdown that turns it back off.
///
/// Sits directly under the toggle because it modifies it — this is how long the
/// switch above stays on, not a setting that lives somewhere else.
private struct KeepAwakeDurationRow: View {
    @EnvironmentObject var state: AppState

    private var autoMode: Bool { state.settings.autoEnableWhenCharging }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: L10n.tr("Keep awake for"), minHeight: 32) {
                // A Menu of buttons rather than a Picker: a Picker's binding only
                // fires when the value *changes*, so after a timer had elapsed,
                // choosing the same duration again would do nothing at all —
                // exactly when someone wants another fifteen minutes.
                Menu {
                    Button(AutoOff.durationLabel(minutes: 0)) { state.keepAwakeFor(minutes: 0) }
                    ForEach(AutoOff.presetMinutes, id: \.self) { minutes in
                        Button(AutoOff.optionLabel(minutes: minutes)) {
                            state.keepAwakeFor(minutes: minutes)
                        }
                    }
                } label: {
                    Text(AutoOff.durationLabel(minutes: state.autoOffMinutes))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(autoMode)
            }

            if !state.autoOffRemaining.isEmpty {
                Label(L10n.format("Turning off in %@", state.autoOffRemaining), systemImage: "timer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if autoMode {
                // Auto mode decides activation itself, so a countdown would
                // disarm the feature behind its back. Say so rather than leaving
                // a control that looks live and does nothing.
                Text(L10n.tr("Not used while “Automatically enable when charging” is on."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
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
                Text(state.usingHelper ? L10n.tr("Helper active") : L10n.tr("Helper inactive"))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.usingHelper ? L10n.tr("Background helper active") : L10n.tr("Background helper inactive"))

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: batterySymbol)
                Text(L10n.format("Battery %d%%", state.batteryPercent))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.batteryOnAC
                ? L10n.format("Battery %d percent, on power", state.batteryPercent)
                : L10n.format("Battery %d percent", state.batteryPercent))
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
            Text(L10n.tr("Safety"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            SettingRow(title: L10n.tr("Only while charging")) {
                Toggle(L10n.tr("Only while charging"), isOn: Binding(
                    get: { state.settings.onlyWhileCharging },
                    set: { v in var s = state.settings; s.onlyWhileCharging = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingRow(title: L10n.tr("Pause when running hot")) {
                Toggle(L10n.tr("Pause when running hot"), isOn: Binding(
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
private struct LowBatteryCutoffRow: View {
    @EnvironmentObject var state: AppState

    /// The value shown while dragging. Committing on every step would write
    /// UserDefaults — and, in auto mode, run a reconcile that can reach the
    /// privileged helper — once per 5% of travel, so the commit waits for the
    /// drag to end.
    @State private var dragging: Double?

    private var threshold: Int { state.settings.lowBatteryThreshold }

    /// The committed value, or the in-flight one while a drag is in progress.
    private var shown: Int { Int((dragging ?? Double(threshold)).rounded()) }

    /// The cutoff only ever fires off power, so it's meaningless whenever
    /// keep-awake is already gated on being plugged in — under "Only while
    /// charging", and equally under auto mode, which requires external power.
    private var isInactive: Bool {
        state.settings.onlyWhileCharging || state.settings.autoEnableWhenCharging
    }

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
                Text(L10n.tr("Low-battery cutoff"))
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(shown == 0 ? L10n.tr("Never") : L10n.format("%d%%", shown))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: value,
                   in: 0...100,
                   step: 5,
                   label: { Text(L10n.tr("Low-battery cutoff")) },
                   minimumValueLabel: { Text(L10n.tr("Never")).font(.caption2).foregroundStyle(.secondary) },
                   maximumValueLabel: { Text(L10n.format("%d%%", 100)).font(.caption2).foregroundStyle(.secondary) },
                   onEditingChanged: commit)
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
        .disabled(isInactive)
    }
}

// MARK: - Auto-mode warning

/// Shown directly under the primary toggle when auto mode is armed but keep-awake
/// isn't live right now, listing every safety check currently blocking it.
private struct AutoDisabledWarning: View {
    let reasons: [SafetyReason]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemYellow))
                Text(L10n.tr("Automatic mode is on, but keep-awake isn’t active right now."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            Text(L10n.tr("Temporarily disabled because the following check(s) failed:"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    Text(L10n.format("• %@", reason.checkLabel))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
        }
    }
}

// MARK: - Automatic

private struct AutomaticSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("Automatic"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            SettingRow(title: L10n.tr("Automatically enable when charging")) {
                Toggle(L10n.tr("Automatically enable when charging"), isOn: Binding(
                    get: { state.settings.autoEnableWhenCharging },
                    set: { v in var s = state.settings; s.autoEnableWhenCharging = v; state.updateSettings(s) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
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
                Label(L10n.tr("Quit Lidless"), systemImage: "power")
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .frame(minHeight: 36)
    }
}

/// Opens the Settings window. Neither `SettingsLink` nor `showSettingsWindow:`
/// reliably activates an LSUIElement app (issue #22), so a plain button drives
/// the AppKit-backed `SettingsWindowController` through `AppState`.
private struct SettingsButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            // The popover won't close on its own: SwiftUI's `dismiss()` can't
            // reach it, and an accessory app can't reliably take key away from it.
            MenuBarExtraPanel.dismiss()
            state.showSettings()
        } label: {
            Label(L10n.tr("Settings…"), systemImage: "gearshape")
                .foregroundStyle(.secondary)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
