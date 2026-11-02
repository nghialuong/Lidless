import AppKit
import SwiftUI
import XCTest

/// Covers the AppKit-backed Settings window introduced for issue #22: the
/// window is reused while open and rebuilt after a close, because a closed
/// window's SwiftUI graph leaks observation registrations.
@MainActor
final class SettingsWindowControllerTests: XCTestCase {

    private let autosaveName = "LidlessSettingsWindowTests"
    private let contentSize = CGSize(width: 420, height: 460)

    /// Counts how many times the content factory ran, so we can assert the
    /// window (and its SwiftUI content) is built exactly once.
    private final class BuildCounter {
        var count = 0
    }

    private func makeController(counter: BuildCounter = BuildCounter()) -> SettingsWindowController {
        SettingsWindowController(title: "Lidless Settings",
                                 contentSize: contentSize,
                                 frameAutosaveName: autosaveName) {
            counter.count += 1
            return AnyView(Color.clear)
        }
    }

    override func tearDown() {
        // Don't leave a saved frame behind in the test runner's defaults.
        NSWindow.removeFrame(usingName: autosaveName)
        super.tearDown()
    }

    func testWindowIsBuiltLazilyOnFirstShow() {
        let sut = makeController()
        XCTAssertNil(sut.window)
        sut.show()
        XCTAssertNotNil(sut.window)
    }

    func testSecondShowReusesTheSameWindow() {
        let counter = BuildCounter()
        let sut = makeController(counter: counter)

        sut.show()
        let first = sut.window
        sut.show()

        XCTAssertTrue(sut.window === first, "show() must not stack duplicate windows")
        XCTAssertEqual(counter.count, 1, "content should be built once, not per show()")
    }

    /// Closing releases the window: a closed window's hosting view keeps
    /// re-rendering on `AppState` changes and leaks SwiftUI observation
    /// registrations, so the controller must drop it and rebuild on reopen.
    func testCloseReleasesTheWindowAndShowRebuildsIt() {
        let counter = BuildCounter()
        let sut = makeController(counter: counter)

        sut.show()
        let first = sut.window
        sut.close()
        XCTAssertNil(sut.window, "close() must release the window")

        sut.show()
        XCTAssertTrue(sut.window !== first, "reopen must build a new window")
        XCTAssertEqual(sut.window?.isVisible, true)
        XCTAssertEqual(counter.count, 2, "content should be rebuilt after close")
    }

    func testWindowConfiguration() throws {
        let sut = makeController()
        sut.show()
        let window = try XCTUnwrap(sut.window)

        XCTAssertEqual(window.title, "Lidless Settings")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        // SettingsView pins its own 420x460 frame, so the window must not resize.
        XCTAssertFalse(window.styleMask.contains(.resizable))
        // Required for reuse: a released window would dangle after the user closes it.
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentViewController is NSHostingController<AnyView>)
    }

    /// An accessory app deactivates constantly and the user may have switched
    /// Spaces since the window was last shown; either would hide it.
    func testWindowFollowsTheUserRatherThanHiding() throws {
        let sut = makeController()
        sut.show()
        let window = try XCTUnwrap(sut.window)

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.hidesOnDeactivate)
    }

    /// `orderFrontRegardless()` shows the window even when the app hasn't won
    /// activation — which for an accessory app is the common case.
    ///
    /// The companion behaviour, taking key (which is what dismisses the
    /// MenuBarExtra popover), isn't asserted here: the `xctest` runner is never
    /// the active app, so no window in it can become key. That part is manual QA.
    func testShowMakesTheWindowVisible() throws {
        let sut = makeController()
        sut.show()
        XCTAssertTrue(try XCTUnwrap(sut.window).isVisible)
    }

    /// The hosting controller's fitting size is unresolved before display, so
    /// the window must take the size it was given instead of inheriting one.
    func testWindowUsesTheRequestedContentSize() throws {
        let sut = makeController()
        sut.show()
        let size = try XCTUnwrap(sut.window?.contentView?.frame.size)

        XCTAssertEqual(size.width, contentSize.width, accuracy: 1)
        XCTAssertEqual(size.height, contentSize.height, accuracy: 1)
    }
}
