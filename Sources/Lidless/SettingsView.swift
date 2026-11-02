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
                        Image(systemName: helperStatusSymbol)
                            .foregroundStyle(helperHealthy ? .green : .orange)
                        Text(helperStatusText)
                            .foregroundStyle(.secondary)
                    }
                }
                // Driven by `helperHealth`, same vocabulary as the popover
                // and onboarding: an installed-but-unreachable helper still
                // needs an action here (Reinstall), which `helperInstalled`
                // alone would hide since the registration itself is fine.
                switch state.helperHealth {
                case .healthy, .checking:
                    EmptyView()
                case .unreachable:
                    Text("The background helper is registered but isn’t responding. This usually happens after an update.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Reinstall background helper…") {
                        state.repairHelper()
                    }
                case .needsApproval:
                    Text("Install the background helper once so toggling never asks for your password and the watchdog can protect against a stuck-awake Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items to approve…") {
                        state.installHelper()
                    }
                case .notInstalled:
                    Text("Install the background helper once so toggling never asks for your password and the watchdog can protect against a stuck-awake Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Install background helper…") {
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
        .onAppear { state.checkHelperNow() }
        .formStyle(.grouped)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }

    /// Same vocabulary as the popover's status strip, so Settings can never
    /// contradict it.
    private var helperHealthy: Bool { state.helperHealth == .healthy }

    private var helperStatusText: String {
        switch state.helperHealth {
        case .notInstalled: return "Using admin prompt"
        case .needsApproval: return "Awaiting approval"
        case .checking: return "Checking…"
        case .unreachable: return "Not responding"
        case .healthy: return "Active"
        }
    }

    private var helperStatusSymbol: String {
        helperHealthy ? "checkmark.shield.fill" : "exclamationmark.shield"
    }
}
