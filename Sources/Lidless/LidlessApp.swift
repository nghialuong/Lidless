import SwiftUI

@main
struct LidlessApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Image(state.isEnabled ? "MenubarLaptopActive" : "MenubarLaptop")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(updater)
        }
    }
}
