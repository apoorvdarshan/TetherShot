import XCTest
@testable import TetherShot

final class BackgroundPreferenceStoreTests: XCTestCase {
    func testNewUserStartsWithRecommendedDefaults() {
        let defaults = makeDefaults()
        var launchAtLoginRequests: [Bool] = []

        let state = BackgroundPreferenceStore.bootstrap(
            defaults: defaults,
            launchAtLoginIsEnabled: false,
            setLaunchAtLogin: {
                launchAtLoginRequests.append($0)
                return $0
            }
        )

        XCTAssertEqual(
            state,
            BackgroundPreferenceState(
                showInMenuBar: true,
                showInDock: false,
                launchAtLogin: true,
                autoCheckForUpdates: true,
                autoInstallUpdates: true
            )
        )
        XCTAssertEqual(launchAtLoginRequests, [true])
        XCTAssertEqual(defaults.object(forKey: "showInMenuBar") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "showInDock") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "launchAtLogin") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "autoCheckForUpdates") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "autoInstallUpdates") as? Bool, true)
    }

    func testExistingUserChoicesArePreserved() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "showInMenuBar")
        defaults.set(false, forKey: "showInDock")
        defaults.set(false, forKey: "autoCheckForUpdates")
        defaults.set(false, forKey: "autoInstallUpdates")
        var launchAtLoginWasChanged = false

        let state = BackgroundPreferenceStore.bootstrap(
            defaults: defaults,
            launchAtLoginIsEnabled: false,
            setLaunchAtLogin: { _ in
                launchAtLoginWasChanged = true
                return true
            }
        )

        XCTAssertEqual(
            state,
            BackgroundPreferenceState(
                showInMenuBar: false,
                showInDock: false,
                launchAtLogin: false,
                autoCheckForUpdates: false,
                autoInstallUpdates: false
            )
        )
        XCTAssertFalse(launchAtLoginWasChanged)
    }

    func testExistingUserWithoutNewerChoicesKeepsLegacyDefaults() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "copyToClipboard")

        let state = BackgroundPreferenceStore.bootstrap(
            defaults: defaults,
            launchAtLoginIsEnabled: false,
            setLaunchAtLogin: { _ in
                XCTFail("An existing user should not be registered at login")
                return true
            }
        )

        XCTAssertEqual(
            state,
            BackgroundPreferenceState(
                showInMenuBar: true,
                showInDock: true,
                launchAtLogin: false,
                autoCheckForUpdates: true,
                autoInstallUpdates: false
            )
        )
    }

    func testBootstrapOnlyRegistersLaunchAtLoginOnce() {
        let defaults = makeDefaults()
        var registrationCount = 0

        _ = BackgroundPreferenceStore.bootstrap(
            defaults: defaults,
            launchAtLoginIsEnabled: false,
            setLaunchAtLogin: { enabled in
                registrationCount += 1
                return enabled
            }
        )
        let secondState = BackgroundPreferenceStore.bootstrap(
            defaults: defaults,
            launchAtLoginIsEnabled: true,
            setLaunchAtLogin: { enabled in
                registrationCount += 1
                return enabled
            }
        )

        XCTAssertEqual(registrationCount, 1)
        XCTAssertTrue(secondState.launchAtLogin)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "BackgroundPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
