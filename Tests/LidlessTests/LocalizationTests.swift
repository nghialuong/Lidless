import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testLanguageOverrideIsAppScopedAndSystemChoiceRemovesIt() {
        let suite = "LidlessTests.Language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(InterfaceLanguage.current(in: defaults), .system)
        InterfaceLanguage.simplifiedChinese.save(to: defaults)
        XCTAssertEqual(InterfaceLanguage.current(in: defaults), .simplifiedChinese)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])

        InterfaceLanguage.english.save(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

        InterfaceLanguage.system.save(to: defaults)
        XCTAssertEqual(InterfaceLanguage.current(in: defaults), .system)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }

    func testUnknownStoredLanguageFallsBackToSystem() {
        let suite = "LidlessTests.Language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported", forKey: InterfaceLanguage.preferenceKey)
        XCTAssertEqual(InterfaceLanguage.current(in: defaults), .system)
    }

    func testSourceTextRemainsUsableWithoutAppResources() {
        XCTAssertEqual(L10n.tr("Missing key used only by this test"), "Missing key used only by this test")
        XCTAssertEqual(L10n.format("Battery %d%%", 42), "Battery 42%")
    }
}
