import XCTest
@testable import TetherShot

final class HiddenDevicePreferenceTests: XCTestCase {
    func testPreferencesRoundTrip() {
        let suiteName = "TetherShotTests.HiddenDevices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = [
            HiddenDevicePreference(id: "phone-2", name: "Demo iPhone"),
        ]
        HiddenDevicePreferenceStore.save(preferences, defaults: defaults)

        XCTAssertEqual(HiddenDevicePreferenceStore.load(defaults: defaults), preferences)
    }

    func testHiddenDevicesAreExcludedFromVisibleCaptureList() {
        let devices = [
            CaptureDevice(id: "phone-1", name: "Personal iPhone", connection: .usb),
            CaptureDevice(id: "phone-2", name: "Demo iPhone", connection: .wireless),
        ]
        let hidden = [HiddenDevicePreference(id: "phone-2", name: "Demo iPhone")]

        XCTAssertEqual(
            CaptureDeviceVisibility.visibleDevices(from: devices, hidden: hidden),
            [devices[0]]
        )
        XCTAssertEqual(
            CaptureDeviceVisibility.hiddenConnectedCount(in: devices, hidden: hidden),
            1
        )
    }
}
