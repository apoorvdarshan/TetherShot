import XCTest
@testable import TetherShot

final class CaptureDeviceMergerTests: XCTestCase {
    func testSameIPhoneOverUSBAndWiFiAppearsOnceAndPrefersUSB() {
        let udid = "00008110-001234567890001E"
        let devices = [
            CaptureDevice(
                id: DeviceIdentity.iOS(rawID: udid),
                captureID: udid,
                name: "Apoorv’s iPhone",
                connection: .wireless
            ),
            CaptureDevice(
                id: DeviceIdentity.iOS(rawID: "AVCapture-\(udid)"),
                captureID: "AVCapture-\(udid)",
                name: "iPhone …001E",
                connection: .usb
            ),
        ]

        let merged = CaptureDeviceMerger.merge(devices)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].connection, .usb)
        XCTAssertEqual(merged[0].captureID, "AVCapture-\(udid)")
        XCTAssertEqual(merged[0].name, "Apoorv’s iPhone")
        XCTAssertEqual(merged[0].availableConnections, [.usb, .wireless])
    }

    func testAndroidIdentityUsesHardwareIDInsteadOfTransportSerial() {
        XCTAssertEqual(
            DeviceIdentity.android(androidID: "A1B2C3\n", adbSerial: "192.168.1.2:5555"),
            "android:a1b2c3"
        )
    }
}
