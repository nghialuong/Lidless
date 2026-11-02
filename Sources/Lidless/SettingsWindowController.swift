import AppKit
import SwiftUI

/// Hosts the Settings window in a standalone AppKit window.
///
/// Lidless is an `LSUIElement` menu-bar app with no Dock presence, so SwiftUI's
/// `Settings` scene doesn't reliably surface: `SettingsLink` (macOS 14+) never
/// activates an accessory app, and the `showSettingsWindow:` selector isn't a
/// dependable way to present the scene. A plain `NSWindow` gives precise control
/// over showing, focusing, and closing — the same reasoning as
/// `OnboardingController`.
///
/// The content arrives as a view factory rather than a concrete view, so this
/// file depends only on AppKit/SwiftUI and can be compiled into the unit-test
/// bundle (which can't link the app target).
@MainActor
final class SettingsWindowController {
    private let title: String
    private let contentSize: CGSize
    private let frameAutosaveName: String
    private let makeContent: () -> AnyView

    private(set) var window: NSWindow?

    private var willCloseObserver: NSObjectProtocol?

    init(title: String = "Lidless Settings",
         contentSize: CGSize,
         frameAutosaveName: String = "LidlessSettingsWindow",
         makeContent: @escaping () -> AnyView) {
        self.title = title
        self.contentSize = contentSize
        self.frameAutosaveName = frameAutosaveName
        self.makeContent = makeContent
    }

    /// Show the window. It is reused while open and rebuilt after a close:
    /// a closed window's hosting view keeps re-rendering on `AppState` changes
    /// and leaks SwiftUI observation registrations, so closing releases it.
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent())
            let win = NSWindow(contentViewController: hosting)
            win.title = title
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            // Follow the user to whichever Space they're on; without this the
            // window can re-open on the Space it was last shown and read as
            // "Settings did nothing".
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            // An accessory app deactivates constantly; don't vanish with it.
            win.hidesOnDeactivate = false
            // The hosting controller's fitting size isn't resolved before the
            // window is displayed, so state the size rather than inherit it.
            win.setContentSize(contentSize)
            // Center on creation, then let the autosave name remember wherever
            // the user drags it. Setting the name last means a saved frame wins.
            win.center()
            win.setFrameAutosaveName(frameAutosaveName)
            window = win
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseWindow() }
            }
        }

        if #available(macOS 14.0, *) {
            // `ignoringOtherApps:` is deprecated here, and since Sonoma macOS
            // declines to activate an accessory app through it anyway.
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        // Activation alone doesn't reliably front the window for an accessory
        // app, so order it front regardless of whether we won activation, then
        // take key separately. `makeKeyAndOrderFront` does neither dependably
        // here. Taking key isn't guaranteed either — without activation the
        // window may never become key — which is why dismissing the menu-bar
        // popover is `MenuBarExtraPanel`'s job rather than a side effect of this.
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func close() {
        window?.close()
    }

    /// Drop the closed window and its hosting controller so the SwiftUI graph
    /// stops re-rendering (and leaking observation registrations) while hidden.
    private func releaseWindow() {
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
            self.willCloseObserver = nil
        }
        window?.contentViewController = nil
        window = nil
    }
}
