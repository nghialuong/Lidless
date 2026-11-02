import XCTest

final class SettingsMigrationTests: XCTestCase {
    func testUnseededDomainMigratesOnlyUserPreferencesAndLeavesLegacyUntouched() {
        let legacyName = "com.mjaverto.lidless.tests.legacy.\(UUID().uuidString)"
        let destinationName = "com.mjaverto.lidless.tests.destination.\(UUID().uuidString)"
        let source = UserDefaults.standard
        let destination = UserDefaults(suiteName: destinationName)!
        defer {
            source.removePersistentDomain(forName: legacyName)
            destination.removePersistentDomain(forName: destinationName)
        }

        let legacy: [String: Any] = [
            "lowBatteryThreshold": 37,
            "onlyWhileCharging": true,
            "pauseOnHighThermal": false,
            "autoEnableWhenCharging": true,
            "keepAwakeArmed": true,
            "settingsSeeded": true,
            "autoOffMinutes": 120,
            "onboardingComplete": true,
            "resumeOnboarding": true,
            "lastRegisteredHelperBuild": "upstream-helper-build",
            "SUEnableAutomaticChecks": false,
            "unrelatedPreference": "must not migrate",
        ]
        source.setPersistentDomain(legacy, forName: legacyName)
        destination.removePersistentDomain(forName: destinationName)
        let store = SettingsStore(defaults: destination)

        XCTAssertTrue(store.migrateLegacyPreferencesIfNeeded(from: legacyName, source: source))
        XCTAssertEqual(
            store.load(),
            SafetySettings(
                lowBatteryThreshold: 37,
                onlyWhileCharging: true,
                pauseOnHighThermal: false,
                autoEnableWhenCharging: true
            )
        )
        XCTAssertTrue(store.loadArmed())
        XCTAssertEqual(store.loadAutoOffMinutes(), 120)
        XCTAssertTrue(store.loadOnboardingComplete())
        XCTAssertTrue(store.loadResumeOnboarding())
        XCTAssertEqual(store.loadLastHelperBuild(), "")
        XCTAssertNil(destination.object(forKey: "unrelatedPreference"))
        XCTAssertEqual(destination.object(forKey: "SUEnableAutomaticChecks") as? Bool,
                       false)
        XCTAssertEqual(source.persistentDomain(forName: legacyName)! as NSDictionary,
                       legacy as NSDictionary)

        var changedLegacy = legacy
        changedLegacy["keepAwakeArmed"] = false
        source.setPersistentDomain(changedLegacy, forName: legacyName)
        XCTAssertFalse(store.migrateLegacyPreferencesIfNeeded(from: legacyName, source: source))
        XCTAssertTrue(store.loadArmed(), "migration must run only once")
    }

    func testSeededDestinationIsNeverOverwrittenByLegacyPreferences() {
        let legacyName = "com.mjaverto.lidless.tests.seeded-legacy.\(UUID().uuidString)"
        let destinationName = "com.mjaverto.lidless.tests.seeded-destination.\(UUID().uuidString)"
        let source = UserDefaults.standard
        let destination = UserDefaults(suiteName: destinationName)!
        defer {
            source.removePersistentDomain(forName: legacyName)
            destination.removePersistentDomain(forName: destinationName)
        }

        source.setPersistentDomain([
            "lowBatteryThreshold": 10,
            "onlyWhileCharging": true,
            "pauseOnHighThermal": false,
            "autoEnableWhenCharging": true,
            "settingsSeeded": true,
            "keepAwakeArmed": true,
            "autoOffMinutes": 240,
        ], forName: legacyName)
        destination.removePersistentDomain(forName: destinationName)
        let store = SettingsStore(defaults: destination)
        let current = SafetySettings(
            lowBatteryThreshold: 65,
            onlyWhileCharging: false,
            pauseOnHighThermal: true,
            autoEnableWhenCharging: false
        )
        store.save(current)
        store.saveArmed(false)
        store.saveAutoOffMinutes(15)

        XCTAssertFalse(store.migrateLegacyPreferencesIfNeeded(from: legacyName, source: source))
        XCTAssertEqual(store.load(), current)
        XCTAssertFalse(store.loadArmed())
        XCTAssertEqual(store.loadAutoOffMinutes(), 15)
    }

    func testLegacyDomainConstantRemainsTheExactUpstreamIdentity() {
        XCTAssertEqual(SettingsStore.legacyDefaultsDomain, "com.nghialuong.lidless")
    }

    func testMissingLegacyDomainCompletesWithoutInventingPreferences() {
        let legacyName = "com.mjaverto.lidless.tests.missing-legacy.\(UUID().uuidString)"
        let destinationName = "com.mjaverto.lidless.tests.missing-destination.\(UUID().uuidString)"
        let source = UserDefaults.standard
        let destination = UserDefaults(suiteName: destinationName)!
        defer {
            source.removePersistentDomain(forName: legacyName)
            destination.removePersistentDomain(forName: destinationName)
        }
        source.removePersistentDomain(forName: legacyName)
        destination.removePersistentDomain(forName: destinationName)
        let store = SettingsStore(defaults: destination)

        XCTAssertFalse(store.migrateLegacyPreferencesIfNeeded(
            from: legacyName,
            source: source
        ))
        XCTAssertNil(destination.object(forKey: "lowBatteryThreshold"))
        XCTAssertNil(destination.object(forKey: "SUEnableAutomaticChecks"))

        source.setPersistentDomain([
            "lowBatteryThreshold": 20,
            "settingsSeeded": true,
            "SUEnableAutomaticChecks": false,
        ], forName: legacyName)
        XCTAssertFalse(store.migrateLegacyPreferencesIfNeeded(
            from: legacyName,
            source: source
        ))
        XCTAssertNil(destination.object(forKey: "lowBatteryThreshold"),
                     "an absent source still completes the one-shot migration")
        XCTAssertNil(destination.object(forKey: "SUEnableAutomaticChecks"))
    }

    func testPartialDestinationMergesOnlyMissingLegacyPreferences() {
        let legacyName = "com.mjaverto.lidless.tests.partial-legacy.\(UUID().uuidString)"
        let destinationName = "com.mjaverto.lidless.tests.partial-destination.\(UUID().uuidString)"
        let source = UserDefaults.standard
        let destination = UserDefaults(suiteName: destinationName)!
        defer {
            source.removePersistentDomain(forName: legacyName)
            destination.removePersistentDomain(forName: destinationName)
        }

        source.setPersistentDomain([
            "lowBatteryThreshold": 37,
            "onlyWhileCharging": true,
            "pauseOnHighThermal": false,
            "autoEnableWhenCharging": true,
            "settingsSeeded": true,
            "keepAwakeArmed": true,
            "autoOffMinutes": 120,
            "SUEnableAutomaticChecks": false,
        ], forName: legacyName)
        destination.removePersistentDomain(forName: destinationName)
        destination.set(72, forKey: "lowBatteryThreshold")
        destination.set(false, forKey: "keepAwakeArmed")
        destination.set(true, forKey: "SUEnableAutomaticChecks")
        let store = SettingsStore(defaults: destination)

        XCTAssertTrue(store.migrateLegacyPreferencesIfNeeded(
            from: legacyName,
            source: source
        ))
        XCTAssertEqual(
            store.load(),
            SafetySettings(
                lowBatteryThreshold: 72,
                onlyWhileCharging: true,
                pauseOnHighThermal: false,
                autoEnableWhenCharging: true
            )
        )
        XCTAssertFalse(store.loadArmed())
        XCTAssertEqual(store.loadAutoOffMinutes(), 120)
        XCTAssertEqual(destination.object(forKey: "SUEnableAutomaticChecks") as? Bool,
                       true)
    }
}
