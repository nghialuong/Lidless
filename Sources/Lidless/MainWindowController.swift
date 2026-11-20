import AppKit
import SwiftUI

/// Hosts Lidless's primary control panel (`MenuContent`) in a standalone AppKit
/// window so launching or reopening `Lidless.app` always surfaces a usable
/// foreground window — even when the menu-bar icon is hidden by macOS 26/27
/// Menu Bar settings or a menu-bar manager.
@MainActor
final class MainWindowController {
    private let title: String
    private let initialContentSize: CGSize
    private let frameAutosaveName: String
    private let makeContent: () -> AnyView

    private(set) var window: NSWindow?

    init(title: String = "Lidless",
         initialContentSize: CGSize = CGSize(width: 360, height: 500),
         frameAutosaveName: String = "LidlessMainWindow",
         makeContent: @escaping () -> AnyView) {
        self.title = title
        self.initialContentSize = initialContentSize
        self.frameAutosaveName = frameAutosaveName
        self.makeContent = makeContent
    }

    /// True while the main control window is currently on screen.
    var isVisible: Bool { window?.isVisible == true }

    /// Show the window, creating it on first use and reusing it afterwards.
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent())
            hosting.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: hosting)
            win.title = title
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            win.hidesOnDeactivate = false
            win.setContentSize(initialContentSize)
            win.center()
            win.setFrameAutosaveName(frameAutosaveName)
            window = win
        }

        if let window {
            ForegroundWindowActivation.present(window)
        }
    }

    func close() {
        window?.close()
    }
}
