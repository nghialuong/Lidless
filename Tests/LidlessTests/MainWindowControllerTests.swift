import AppKit
import SwiftUI
import XCTest

@MainActor
final class MainWindowControllerTests: XCTestCase {

    private let autosaveName = "LidlessMainWindowTests"

    private final class BuildCounter {
        var count = 0
    }

    private func makeController(counter: BuildCounter = BuildCounter()) -> MainWindowController {
        MainWindowController(title: "Lidless",
                             initialContentSize: CGSize(width: 360, height: 500),
                             frameAutosaveName: autosaveName) {
            counter.count += 1
            return AnyView(Color.clear.frame(width: 360, height: 500))
        }
    }

    override func tearDown() {
        NSWindow.removeFrame(usingName: autosaveName)
        super.tearDown()
    }

    func testWindowIsBuiltLazilyAndReused() {
        let counter = BuildCounter()
        let sut = makeController(counter: counter)

        XCTAssertNil(sut.window)
        XCTAssertFalse(sut.isVisible)

        sut.show()
        let first = sut.window
        XCTAssertNotNil(first)
        XCTAssertTrue(sut.isVisible)

        sut.show()
        XCTAssertTrue(sut.window === first)
        XCTAssertEqual(counter.count, 1)
    }

    func testShowAfterCloseReopensTheSameWindow() {
        let sut = makeController()

        sut.show()
        let first = sut.window
        sut.close()
        XCTAssertFalse(sut.isVisible)

        sut.show()
        XCTAssertTrue(sut.window === first)
        XCTAssertTrue(sut.isVisible)
    }

    func testWindowFollowsActiveSpaceAndStaysVisibleOnDeactivate() throws {
        let sut = makeController()
        sut.show()
        let window = try XCTUnwrap(sut.window)

        XCTAssertEqual(window.title, "Lidless")
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    func testForegroundWindowClassificationExcludesMenuBarWindows() {
        let window = NSWindow()
        XCTAssertTrue(ForegroundWindowActivation.isForegroundWindow(window))
    }
}
