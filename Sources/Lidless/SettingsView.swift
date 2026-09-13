import SwiftUI

/// The Settings window. Holds the secondary controls and the detailed
/// explanations that used to clutter the menu bar popover: launch at login,
/// background-helper setup, the auto-off timer, and About/GitHub.
struct SettingsView: View {
    /// Fixed size of the window this view lives in — the view isn't resizable,
    /// so `SettingsWindowController` sizes the window from the same constant.
    static let preferredSize = CGSize(width: 420, height: 460)

    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterController

    private let repoURL = URL(string: "https://github.com/mjaverto/Lidless")!

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Button("Show Setup Guide…") { state.showOnboarding() }
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

            // Protections live in the popover, shown only where they can take
            // effect (the Always mode).

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }

            Section("About") {
                HStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lidless").font(.headline)
                        Text("Version \(state.appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Created by Nghia Luong")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Link("View on GitHub", destination: repoURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }
}
