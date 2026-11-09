import XCTest

final class CommandLineToolTests: XCTestCase {

    func testBareCommandReportsStatus() {
        XCTAssertEqual(LidlessCLI.parse([]), .status)
        XCTAssertEqual(LidlessCLI.parse(["status"]), .status)
    }

    func testOffAndHelp() {
        XCTAssertEqual(LidlessCLI.parse(["off"]), .off)
        for flag in ["help", "-h", "--help"] {
            XCTAssertEqual(LidlessCLI.parse([flag]), .help)
        }
    }

    /// There is deliberately no `on`: the notification channel can't tell who
    /// posted, so it only ever lets the Mac sleep. A typo or an extra argument
    /// must not be read as some other command either.
    func testUnknownOrExtraArgumentsAreRejected() {
        XCTAssertNil(LidlessCLI.parse(["on"]))
        XCTAssertNil(LidlessCLI.parse(["of"]))
        XCTAssertNil(LidlessCLI.parse(["off", "now"]))
    }

    /// The `.dev` build and the released app must each hear only their own tool,
    /// the same isolation their helpers get.
    func testStopNotificationIsPerBuild() {
        XCTAssertNotEqual(LidlessCLI.stopNotificationName(appBundleID: "com.nghialuong.lidless"),
                          LidlessCLI.stopNotificationName(appBundleID: "com.nghialuong.lidless.dev"))
    }

    /// The tool path comes from wherever the app was dragged, so a quote or a
    /// backslash in a folder name must stay part of the path, not end the
    /// AppleScript string and let the rest run as script.
    func testInstallScriptKeepsHostilePathInsideTheLiteral() {
        let path = #"/Users/me/Apps "x" \ & rm -rf ~/Lidless.app/Contents/Helpers/lidless"#
        let script = LidlessCLI.installScript(toolPath: path)
        XCTAssertTrue(script.contains(#"quoted form of "/Users/me/Apps \"x\" \\ & rm -rf ~/Lidless.app/Contents/Helpers/lidless""#))
        XCTAssertTrue(script.hasSuffix(#" \#(LidlessCLI.installPath)" with administrator privileges"#))
    }

    // MARK: When `lidless off` may report success

    private let ok = LidlessCLI.StopAck(ok: true, message: nil)

    /// Auto mode armed but paused (unplugged): the flag already reads 0. With no
    /// reply the app hasn't disarmed, and plugging in would turn keep-awake back
    /// on — so this must keep waiting, not report off.
    func testAlreadyOffButArmedWithUnresponsiveAppIsNotDone() {
        XCTAssertEqual(LidlessCLI.offOutcome(ack: nil, flag: false, autoMode: true, armed: true), .waiting)
        XCTAssertEqual(LidlessCLI.offOutcome(ack: nil, flag: false, autoMode: false, armed: false), .waiting)
    }

    func testDoneNeedsReplyFlagOffAndDisarmed() {
        XCTAssertEqual(LidlessCLI.offOutcome(ack: ok, flag: false, autoMode: true, armed: false), .done)
        XCTAssertEqual(LidlessCLI.offOutcome(ack: ok, flag: false, autoMode: false, armed: true), .done)
    }

    /// Any process can post the reply, so the tool checks the facts itself.
    func testReplyIsNotTakenOnTrust() {
        guard case .failed = LidlessCLI.offOutcome(ack: ok, flag: true, autoMode: false, armed: false) else {
            return XCTFail("flag still 1")
        }
        guard case .failed = LidlessCLI.offOutcome(ack: ok, flag: nil, autoMode: false, armed: false) else {
            return XCTFail("flag unreadable")
        }
        guard case .failed = LidlessCLI.offOutcome(ack: ok, flag: false, autoMode: true, armed: true) else {
            return XCTFail("still armed")
        }
    }

    func testFailedReplyCarriesTheAppsReason() {
        let ack = LidlessCLI.StopAck(ok: false, message: "Authorization cancelled.")
        XCTAssertEqual(LidlessCLI.offOutcome(ack: ack, flag: true, autoMode: false, armed: false),
                       .failed("Authorization cancelled."))
    }

    /// Two agents running `lidless off` at once must each wait for their own reply.
    func testReplyToAnotherRequestIsIgnored() {
        let info: [AnyHashable: Any] = [LidlessCLI.UserInfoKey.requestID: "A",
                                        LidlessCLI.UserInfoKey.ok: true]
        XCTAssertNil(LidlessCLI.StopAck(userInfo: info, requestID: "B"))
        XCTAssertEqual(LidlessCLI.StopAck(userInfo: info, requestID: "A"), ok)
        XCTAssertNil(LidlessCLI.StopAck(userInfo: [LidlessCLI.UserInfoKey.requestID: "A"], requestID: "A"))
    }
}
