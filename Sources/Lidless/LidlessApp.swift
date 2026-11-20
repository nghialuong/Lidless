import AppKit
import SwiftUI

@MainActor
final class LidlessAppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStandardMenusIfNeeded()

        // First-run onboarding already presents itself; stay quiet only when
        // macOS auto-launched Lidless in the background at login.
        if !state.willShowOnboardingOnLaunch && !Self.wasLaunchedAsLoginItem() {
            state.showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening Lidless.app (from Applications, Spotlight, Dock, or `open`)
        // should always bring a usable window to the foreground instead of
        // silently doing nothing behind LSUIElement.
        state.presentForegroundUI()
        return true
    }

    private static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Ensure Cmd+W / Cmd+, / Cmd+Q work cleanly whenever Lidless promotes to
    /// `.regular` while a foreground window is open.
    private func installStandardMenusIfNeeded() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if mainMenu.items.isEmpty {
            let appMenuItem = NSMenuItem()
            let appMenu = NSMenu(title: "Lidless")
            appMenu.addItem(
                withTitle: "Settings…",
                action: #selector(openSettingsFromMenu),
                keyEquivalent: ","
            ).target = self
            appMenu.addItem(.separator())
            appMenu.addItem(
                withTitle: "Quit Lidless",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            appMenuItem.submenu = appMenu
            mainMenu.addItem(appMenuItem)
        }

        let hasClose = mainMenu.items.contains { item in
            item.submenu?.items.contains { $0.action == #selector(NSWindow.performClose(_:)) } == true
        }
        if !hasClose {
            let fileMenuItem = NSMenuItem()
            let fileMenu = NSMenu(title: "File")
            fileMenu.addItem(
                withTitle: "Close Window",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
            fileMenuItem.submenu = fileMenu
            mainMenu.addItem(fileMenuItem)
        }

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        state.showSettings()
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(state.isEnabled ? "MenubarLaptopActive" : "MenubarLaptop")
    }
}

@main
struct LidlessApp: App {
    @NSApplicationDelegateAdaptor(LidlessAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appDelegate.state)
        } label: {
            MenuBarIcon(state: appDelegate.state)
        }
        .menuBarExtraStyle(.window)
        // No `Settings` scene: it doesn't reliably surface in an LSUIElement app
        // (issue #22). `AppState.showSettings()` presents it via AppKit instead.
    }
}
