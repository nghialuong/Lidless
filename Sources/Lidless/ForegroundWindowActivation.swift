import AppKit

/// Coordinates foreground window presentation for an `LSUIElement` menu-bar app.
///
/// On macOS 14–27, accessory (`LSUIElement`) apps are routinely denied activation
/// and key-window focus even when calling `NSApp.activate()` or
/// `makeKeyAndOrderFront(_:)`. Promoting the app to `.regular` while a standard
/// window (main control window, Settings, or Onboarding) is visible — and
/// returning to `.accessory` once all standard windows close — lets macOS
/// reliably bring windows to the foreground and focus them while keeping the
/// Dock clean in background menu-bar mode.
@MainActor
enum ForegroundWindowActivation {
    private static var closeObserver: NSObjectProtocol?

    /// Returns true if `window` is a standard foreground window (as opposed to
    /// the menu bar status item or `MenuBarExtra` popover).
    static func isForegroundWindow(_ window: NSWindow) -> Bool {
        let name = window.className
        return !MenuBarExtraPanel.isStatusBarWindow(className: name)
            && !MenuBarExtraPanel.isPanelWindow(className: name)
    }

    /// True if any standard foreground window is currently visible.
    static func hasVisibleForegroundWindow(in windows: [NSWindow]? = nil) -> Bool {
        let list = windows ?? NSApp?.windows ?? []
        return list.contains { $0.isVisible && isForegroundWindow($0) }
    }

    /// True when the running app bundle declares `LSUIElement = true`.
    private static var isAgentApp: Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool {
            return value
        }
        if let str = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? String {
            return (str as NSString).boolValue
        }
        return false
    }

    /// Present `window` in the foreground, promoting from `.accessory` to
    /// `.regular` when needed so macOS grants activation and key focus.
    static func present(_ window: NSWindow) {
        installCloseObserverIfNeeded()

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        let didPromote = promoteToRegularIfNeeded()

        // Order front synchronously so callers (and tests) see the window
        // immediately, even before WindowServer completes any policy transition.
        activateNow()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // When transitioning from `.accessory` (`LSUIElement`) to `.regular`,
        // WindowServer on macOS 14–27 finishes registering the promotion on a
        // subsequent run-loop turn. Re-activating after a short beat ensures
        // the app actually becomes active and the window becomes key.
        if didPromote || !(NSApp?.isActive ?? true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
                guard let window, window.isVisible else { return }
                activateNow()
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Activate the application for alerts or foreground interactions.
    static func activateApp() {
        installCloseObserverIfNeeded()
        _ = promoteToRegularIfNeeded()
        activateNow()
    }

    /// Return to `.accessory` if this is an `LSUIElement` app and no foreground
    /// windows remain visible.
    static func restoreAccessoryPolicyIfIdle() {
        guard isAgentApp, let app = NSApp else { return }
        guard app.activationPolicy() == .regular else { return }
        guard !hasVisibleForegroundWindow(in: app.windows) else { return }
        app.setActivationPolicy(.accessory)
    }

    @discardableResult
    private static func promoteToRegularIfNeeded() -> Bool {
        guard let app = NSApp else { return false }
        guard app.activationPolicy() == .accessory else { return false }
        return app.setActivationPolicy(.regular)
    }

    private static func activateNow() {
        guard let app = NSApp else { return }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        app.activate(ignoringOtherApps: true)
    }

    private static func installCloseObserverIfNeeded() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let closed = notification.object as? NSWindow,
                  isForegroundWindow(closed) else { return }
            // Defer to the next turn so AppKit finishes marking the closing
            // window invisible (and any replacement window has ordered front).
            DispatchQueue.main.async {
                restoreAccessoryPolicyIfIdle()
            }
        }
    }
}
