import SwiftUI

/// The Settings window. Holds the secondary controls and the detailed
/// explanations that used to clutter the menu bar popover: launch at login,
/// background-helper setup, the auto-off timer, and About/GitHub.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    private let repoURL = URL(string: "https://github.com/nghialuong/Lidless")!

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: state.usingHelper ? "checkmark.shield.fill" : "exclamationmark.shield")
                            .foregroundStyle(state.usingHelper ? .green : .orange)
                        Text(state.usingHelper ? "Active" : "Using admin prompt")
                            .foregroundStyle(.secondary)
                    }
                }
                if !state.helperInstalled {
                    Text("Install the background helper once so toggling never asks for your password and the watchdog can protect against a stuck-awake Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(state.helperNeedsApproval ? "Open Login Items to approve…" : "Install background helper…") {
                        state.installHelper()
                    }
                }
            } header: {
                Text("Background helper")
            }

            Section("Auto-off timer") {
                Picker("Turn off after", selection: Binding(
                    get: { state.autoOffMinutes },
                    set: { state.setAutoOffMinutes($0) }
                )) {
                    Text("Never").tag(0)
                    ForEach(AutoOff.presetMinutes, id: \.self) { m in
                        Text(AutoOff.optionLabel(minutes: m)).tag(m)
                    }
                }
                if state.isEnabled, !state.autoOffRemaining.isEmpty {
                    LabeledContent("Turning off in", value: state.autoOffRemaining)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Version", value: "v\(state.appVersion)")
                Link("View on GitHub", destination: repoURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
    }
}
