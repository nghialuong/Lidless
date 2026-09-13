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

            StatusLine()
                .padding(.horizontal, hInset)
                .padding(.top, 12)

            Divider()
                .padding(.horizontal, hInset)
                .padding(.top, 14)

            ModePickerRow()
                .padding(.horizontal, hInset)
                .padding(.top, 12)
                .padding(.bottom, 12)

            if state.keepAwakeMode == .always {
                KeepAwakeDurationRow()
                    .padding(.horizontal, hInset)

                ProtectionControls()
                    .padding(.horizontal, hInset)
                    .padding(.top, 2)
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
                .padding(.top, 12)

            FooterActions()
                .padding(.horizontal, hInset)
                .padding(.bottom, 14)
        }
        .frame(width: 360)
        // The popover is the moment the user actually looks at the picker, so
        // it's the moment it most needs to be true.
        .onAppear { state.refreshState() }
    }
}

// MARK: - Reusable row

/// A native settings-style row: leading label, flexible gap, trailing control
/// pinned to the shared right edge. Shared with ProtectionControls.
struct SettingRow<Trailing: View>: View {
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

// MARK: - Mode picker

/// The single control that decides keep-awake behavior. Replaces the old
/// master toggle + auto-enable + "Only while charging" trio, which together
/// expressed one binary outcome through three switches.
private struct ModePickerRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep awake with lid closed")
                .font(.body.weight(.semibold))
            Picker("Keep awake with lid closed", selection: Binding(
                get: { state.keepAwakeMode },
                set: { state.setKeepAwakeMode($0) }
            )) {
                Text(KeepAwakeMode.always.label).tag(KeepAwakeMode.always)
                Text(KeepAwakeMode.onlyWhileCharging.label).tag(KeepAwakeMode.onlyWhileCharging)
                Text(KeepAwakeMode.off.label).tag(KeepAwakeMode.off)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

// MARK: - Live status

/// One line that is always literally true: awake, or why not. Replaces the
/// old three-line warning block and removes the intent-vs-reality
/// contradiction of a toggle that showed "on" while keep-awake wasn't live.
private struct StatusLine: View {
    @EnvironmentObject var state: AppState

    private var line: (color: Color, icon: String, text: String) {
        if state.keepAwakeMode == .off {
            return (.secondary, "moon.zzz", "Keep-awake off")
        }
        if state.isEnabled {
            if !state.autoOffRemaining.isEmpty {
                return (.green, "bolt.fill", "Awake, \(state.autoOffRemaining) left")
            }
            return (.green, "bolt.fill",
                    state.batteryOnAC ? "Awake, on charger" : "Awake, on battery")
        }
        if let reason = state.autoWarningReasons.first {
            return (Color(nsColor: .systemYellow), "pause.circle.fill",
                    "Paused: \(reason.checkLabel)")
        }
        return (Color(nsColor: .systemYellow), "pause.circle.fill", "Paused")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: line.icon)
                .foregroundStyle(line.color)
            Text(line.text)
                .foregroundStyle(.primary)
        }
        .font(.callout)
        // Headline position: icon carries the state color, text stays
        // primary so the glance reads first.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Keep-awake duration

/// "Keep awake for 15 minutes" as a single gesture: picking a duration arms
/// keep-awake and starts the countdown that disarms it. Only meaningful in
/// the Always mode, so the picker hides it elsewhere.
private struct KeepAwakeDurationRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: "Keep awake for", minHeight: 32) {
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
            }

            if !state.autoOffRemaining.isEmpty {
                Label("Turning off in \(state.autoOffRemaining)", systemImage: "timer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            Label("Settings…", systemImage: "gearshape")
                .foregroundStyle(.secondary)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
