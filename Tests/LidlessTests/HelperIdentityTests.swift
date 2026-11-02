import XCTest

/// Tests for the helper's identity and the code signing requirement it demands
/// of anything connecting to it.
final class HelperIdentityTests: XCTestCase {
    private let productionID = "com.mjaverto.lidless"
    private let developmentID = "com.mjaverto.lidless.dev"

    func testOwnedAppAndServiceIdentitiesAreExact() {
        XCTAssertEqual(LidlessIdentity.productionAppBundleID, productionID)
        XCTAssertEqual(LidlessIdentity.developmentAppBundleID, developmentID)
        XCTAssertEqual(LidlessHelper.label(appBundleID: productionID),
                       "com.mjaverto.lidless.helper")
        XCTAssertEqual(LidlessHelper.label(appBundleID: developmentID),
                       "com.mjaverto.lidless.dev.helper")
        XCTAssertEqual(LidlessHelper.fallbackLabel, "com.mjaverto.lidless.helper")
        XCTAssertEqual(LidlessHelper.teamID, "5NWMRTN5BA")
    }

    func testDiagnosticIdentitiesPreserveProductionAndDevelopmentIsolation() {
        XCTAssertEqual(
            LidlessIdentity.diagnosticSubsystem(appBundleID: productionID),
            "com.mjaverto.lidless"
        )
        XCTAssertEqual(
            LidlessIdentity.diagnosticSubsystem(appBundleID: developmentID),
            "com.mjaverto.lidless.dev"
        )
        XCTAssertEqual(
            LidlessIdentity.diagnosticQueueLabel(
                appBundleID: developmentID,
                component: "process.read"
            ),
            "com.mjaverto.lidless.dev.process.read"
        )

        let productionHelper = LidlessHelper.label(appBundleID: productionID)
        let developmentHelper = LidlessHelper.label(appBundleID: developmentID)
        XCTAssertEqual(
            LidlessHelper.activeLabel(machLabel: productionHelper),
            "com.mjaverto.lidless.helper"
        )
        XCTAssertEqual(
            LidlessHelper.activeLabel(machLabel: developmentHelper),
            "com.mjaverto.lidless.dev.helper"
        )
        XCTAssertEqual(
            LidlessHelper.diagnosticQueueLabel(
                machLabel: developmentHelper,
                component: "watchdog"
            ),
            "com.mjaverto.lidless.dev.helper.watchdog"
        )
    }

    func testAppBundleIDIsInverseOfOwnedLabels() {
        for bundleID in [productionID, developmentID] {
            let label = LidlessHelper.label(appBundleID: bundleID)
            XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: label), bundleID)
        }
    }

    func testAppBundleIDLeavesUnexpectedLabelAlone() {
        XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: "com.example.thing"),
                       "com.example.thing")
        XCTAssertEqual(LidlessHelper.appBundleID(fromLabel: ""), "")
    }

    /// Exact equality protects the peer-validation clauses and their values.
    /// Release demands app identifier, Apple trust anchor, and Team ID; Debug
    /// builds are ad-hoc signed (no Apple anchor or team OU exists for them),
    /// so they pin the bundle identifier alone.
    func testRequirementExactlyPinsProductionIdentityAnchorAndTeam() {
        #if DEBUG
        XCTAssertEqual(
            LidlessHelper.codeSigningRequirement(appBundleID: productionID),
            "identifier \"com.mjaverto.lidless\""
        )
        #else
        XCTAssertEqual(
            LidlessHelper.codeSigningRequirement(appBundleID: productionID),
            "identifier \"com.mjaverto.lidless\" and anchor apple generic and certificate leaf[subject.OU] = \"5NWMRTN5BA\""
        )
        #endif
    }

    func testRequirementExactlyPinsDevelopmentIdentityAnchorAndTeam() {
        #if DEBUG
        XCTAssertEqual(
            LidlessHelper.codeSigningRequirement(appBundleID: developmentID),
            "identifier \"com.mjaverto.lidless.dev\""
        )
        #else
        XCTAssertEqual(
            LidlessHelper.codeSigningRequirement(appBundleID: developmentID),
            "identifier \"com.mjaverto.lidless.dev\" and anchor apple generic and certificate leaf[subject.OU] = \"5NWMRTN5BA\""
        )
        #endif
    }

    /// The daemon derives its demanded app identity from the same launchd label
    /// that names its Mach service.
    func testRequirementDerivedFromServiceLabelMatchesOwningApp() {
        for bundleID in [productionID, developmentID] {
            let serviceLabel = LidlessHelper.label(appBundleID: bundleID)
            XCTAssertEqual(
                LidlessHelper.codeSigningRequirement(
                    appBundleID: LidlessHelper.appBundleID(fromLabel: serviceLabel)
                ),
                LidlessHelper.codeSigningRequirement(appBundleID: bundleID)
            )
        }
    }
}
