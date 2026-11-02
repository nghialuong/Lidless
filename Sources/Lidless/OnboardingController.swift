import AppKit
import SwiftUI

/// Hosts the first-run onboarding flow in a standalone window.
///
/// Lidless is an `LSUIElement` menu-bar app with no Dock presence, so auto-
/// presenting and focusing a window from a SwiftUI `Window` scene is unreliable.
/// A plain AppKit `NSWindow` wrapping the SwiftUI `OnboardingView` gives precise
/// control over showing, centering, focusing, and closing — and mirrors how the
/// Settings window already surfaces.
@MainActor
final class OnboardingController {
    private weak var state: AppState?
    private var window: NSWindow?
    private var willCloseObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
    }

    /// Show the window. It is reused while open and rebuilt after a close:
    /// a closed window's hosting view keeps re-rendering on `AppState` changes
    /// and leaks SwiftUI observation registrations, so closing releases it.
    func show() {
        guard let state else { return }

        if window == nil {
            let root = OnboardingView().environmentObject(state)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Welcome to Lidless"
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.center()
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseWindow() }
            }
            window = win
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
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
