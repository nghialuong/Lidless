import SwiftUI

/// First-run setup walkthrough. Explains what Lidless does and walks the user
/// through the one optional system step — installing the background helper —
/// then hands off to the menu bar. Surfaces existing `AppState` flows only; it
/// introduces no new permission logic.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var step = 0

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .padding(.horizontal, 36)
                .padding(.top, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:  welcomeStep
        case 1:  howItWorksStep
        case 2:  helperStep
        default: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Text(L10n.tr("Welcome to Lidless"))
                .font(.largeTitle.weight(.semibold))
            Text(L10n.tr("Keep your Mac awake — even with the lid closed."))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(L10n.tr("Perfect for letting coding agents, downloads, or builds keep running while you close the lid and carry your Mac around. `caffeinate` can't do this — Lidless can.")))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(symbol: "bolt.fill", title: L10n.tr("How it works"))
            VStack(alignment: .leading, spacing: 16) {
                bullet("macbook", L10n.tr("Overrides the lid-close sleep that normally stops everything when you shut the lid."))
                bullet("thermometer.medium", L10n.tr("Auto-pauses if the Mac runs hot or the battery runs low — so it stays safe unattended."))
                bullet("shield.lefthalf.filled", L10n.tr("A watchdog restores normal sleep if Lidless ever quits or crashes, so your Mac can never get stuck awake."))
            }
            Label(L10n.tr("Keep your Mac plugged in and ventilated under heavy use."), systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var helperStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(symbol: "key.fill", title: L10n.tr("Skip the password prompts"))
            Text(L10n.tr("Install a small background helper so turning keep-awake on and off never asks for your admin password — and the safety watchdog can run."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            helperStatusBox

            Text(L10n.tr("Optional — Lidless still works without it; it'll just ask for your password each time you toggle."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var helperStatusBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.usingHelper {
                Label(L10n.tr("Background helper installed and active."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if state.helperNeedsApproval {
                Label(L10n.tr("Approve Lidless under System Settings ▸ Login Items, then come back here."), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("Open Login Items to approve…")) { state.installHelper() }
            } else {
                Button(L10n.tr("Install background helper…")) { state.installHelper() }
                    .buttonStyle(.borderedProminent)
            }

            if let err = state.lastError, !state.usingHelper {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(symbol: "checkmark.circle.fill", title: L10n.tr("You're all set"))
            Text(LocalizedStringKey(L10n.tr("Click the Lidless icon in the menu bar and flip **Keep awake with lid closed** whenever you need it. Safety options live in Settings.")))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.tr("Launch Lidless at login"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .padding(.top, 8)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L10n.tr("Back")) {
                withAnimation { step -= 1 }
            }
            .disabled(step == 0)
            .opacity(step == 0 ? 0 : 1)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            Button(step == lastStep ? L10n.tr("Done") : L10n.tr("Continue")) {
                if step == lastStep {
                    state.completeOnboarding()
                } else {
                    withAnimation { step += 1 }
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    private func header(symbol: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title.weight(.semibold))
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
