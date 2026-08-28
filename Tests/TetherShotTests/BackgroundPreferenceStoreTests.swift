import XCTest
@testable import TetherShot

final class BackgroundPreferenceStoreTests: XCTestCase {
    func testNewUserStartsWithEveryBackgroundOptionEnabled() {
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
                showInDock: true,
                launchAtLogin: true
            )
        )
        XCTAssertEqual(launchAtLoginRequests, [true])
        XCTAssertEqual(defaults.object(forKey: "showInMenuBar") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "showInDock") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "launchAtLogin") as? Bool, true)
    }

    func testExistingUserChoicesArePreserved() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "showInMenuBar")
        defaults.set(false, forKey: "showInDock")
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
                launchAtLogin: false
            )
        )
        XCTAssertFalse(launchAtLoginWasChanged)
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
