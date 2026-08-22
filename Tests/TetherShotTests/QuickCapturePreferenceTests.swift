import XCTest
@testable import TetherShot

final class QuickCapturePreferenceTests: XCTestCase {
    func testPreferenceRoundTripsAndCanBeCleared() {
        let suiteName = "TetherShotTests.QuickCapture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preference = QuickCaptureDevicePreference(id: "phone-2", name: "Work iPhone")
        QuickCapturePreferenceStore.save(preference, defaults: defaults)
        XCTAssertEqual(QuickCapturePreferenceStore.load(defaults: defaults), preference)

        QuickCapturePreferenceStore.save(nil, defaults: defaults)
        XCTAssertNil(QuickCapturePreferenceStore.load(defaults: defaults))
    }

    func testNoPreferenceTargetsAllConnectedDevices() {
        let devices = sampleDevices()
        XCTAssertEqual(
            QuickCaptureTarget.resolve(devices: devices, preference: nil),
            .all(devices)
        )
    }

    func testPreferenceTargetsOnlyTheMatchingDevice() {
        let devices = sampleDevices()
        let preference = QuickCaptureDevicePreference(id: "phone-2", name: "Work iPhone")
        XCTAssertEqual(
            QuickCaptureTarget.resolve(devices: devices, preference: preference),
            .device(devices[1])
        )
    }

    func testMissingPreferredDeviceDoesNotFallBackToAnotherPhone() {
        let preference = QuickCaptureDevicePreference(id: "missing", name: "Travel iPhone")
        XCTAssertEqual(
            QuickCaptureTarget.resolve(devices: sampleDevices(), preference: preference),
            .preferredDeviceUnavailable
        )
    }

    private func sampleDevices() -> [CaptureDevice] {
        [
            CaptureDevice(id: "phone-1", name: "Personal iPhone", connection: .usb),
            CaptureDevice(id: "phone-2", name: "Work iPhone", connection: .wireless),
        ]
    }
}
