import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lidless")
                .font(.headline)

            Text(state.isEnabled
                 ? "Keeping the Mac awake with the lid closed."
                 : "Mac sleeps normally when the lid closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Keep awake with lid closed", isOn: Binding(
                get: { state.isEnabled },
                set: { _ in state.toggle() }
            ))
            .toggleStyle(.switch)

            Divider()

            // Helper / mode row
            HStack(spacing: 6) {
                Image(systemName: state.usingHelper ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(state.usingHelper ? .green : .orange)
                Text(state.usingHelper
                     ? "Background helper active"
                     : "Using admin prompt (no helper)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.helperInstalled {
                Button(state.helperNeedsApproval ? "Open Login Items to approve" : "Install background helper") {
                    state.installHelper()
                }
                .font(.caption)
            }

            HStack(spacing: 6) {
                Image(systemName: "battery.100")
                    .foregroundStyle(.secondary)
                Text(state.batteryDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Quit Lidless") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 270)
    }
}
