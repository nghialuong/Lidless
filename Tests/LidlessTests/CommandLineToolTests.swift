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
        XCTAssertTrue(script.hasSuffix(#"quoted form of "\#(LidlessCLI.installPath)" & " 0" with administrator privileges"#))
    }

    // MARK: Installing the link

    /// Runs the real install program against a scratch folder owned by the test
    /// user, the same checks root runs against `/usr/local/bin`.
    private func install(_ mode: String = "install", tool: String, at dst: String) -> (ok: Bool, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = LidlessCLI.installArguments(mode: mode, toolPath: tool,
                                                     destination: dst, owner: getuid())
        let err = Pipe()
        proc.standardError = err
        try? proc.run()
        proc.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, msg)
    }

    private var root: URL!
    private var bin: String { root.appendingPathComponent("bin").path }
    private var dst: String { bin + "/lidless" }
    private let tool = "/Applications/Lidless.app/Contents/Helpers/lidless"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func testInstallsIntoAnEmptySlot() throws {
        XCTAssertTrue(install(tool: tool, at: dst).ok)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst), tool)
        XCTAssertTrue(install(tool: tool, at: dst).ok, "reinstalling the same link is a no-op")
    }

    func testRefusesToReplaceARegularFile() throws {
        try "someone else's tool".write(toFile: dst, atomically: true, encoding: .utf8)
        XCTAssertFalse(install(tool: tool, at: dst).ok)
        XCTAssertEqual(try String(contentsOfFile: dst, encoding: .utf8), "someone else's tool")
    }

    /// `ln -sf` into a directory writes a link *inside* it. The program must
    /// refuse instead, and leave the directory empty.
    func testRefusesADirectoryAtTheDestination() throws {
        try fm.createDirectory(atPath: dst, withIntermediateDirectories: false)
        XCTAssertFalse(install(tool: tool, at: dst).ok)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst), [])
    }

    /// A link to a directory is the same trap one step removed.
    func testRefusesALinkToADirectory() throws {
        let elsewhere = root.appendingPathComponent("elsewhere").path
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: dst, withDestinationPath: elsewhere)
        XCTAssertFalse(install(tool: tool, at: dst).ok)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere), [])
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst), elsewhere)
    }

    func testRefusesSomeoneElsesLink() throws {
        try fm.createSymbolicLink(atPath: dst, withDestinationPath: "/opt/homebrew/bin/lidless")
        let result = install(tool: tool, at: dst)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.err.contains("/opt/homebrew/bin/lidless"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst), "/opt/homebrew/bin/lidless")
    }

    /// The app was moved: its old link may be replaced, and only by a link.
    func testReplacesALinkLeftByAnotherCopyOfLidless() throws {
        try fm.createSymbolicLink(atPath: dst,
                                  withDestinationPath: "/Users/me/Downloads/Lidless.app/Contents/Helpers/lidless")
        XCTAssertTrue(install(tool: tool, at: dst).ok)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst), tool)
    }

    /// The folder itself being a link would let the write land anywhere.
    func testRefusesWhenTheFolderIsALink() throws {
        let real = root.appendingPathComponent("real").path
        try fm.createDirectory(atPath: real, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent("linked").path
        try fm.createSymbolicLink(atPath: linked, withDestinationPath: real)
        XCTAssertFalse(install(tool: tool, at: linked + "/lidless").ok)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: real), [])
    }

    func testRefusesAFolderOthersCanWrite() throws {
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: bin)
        XCTAssertFalse(install(tool: tool, at: dst).ok)
        XCTAssertFalse(fm.fileExists(atPath: dst))
    }

    /// `check` runs as the user before the password prompt: it may refuse, but
    /// it must never write.
    func testCheckModeNeverWrites() throws {
        XCTAssertTrue(install("check", tool: tool, at: dst).ok)
        XCTAssertFalse(fm.fileExists(atPath: dst))
        try fm.createSymbolicLink(atPath: dst,
                                  withDestinationPath: "/Users/me/Downloads/Lidless.app/Contents/Helpers/lidless")
        XCTAssertTrue(install("check", tool: tool, at: dst).ok)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst),
                       "/Users/me/Downloads/Lidless.app/Contents/Helpers/lidless")
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
