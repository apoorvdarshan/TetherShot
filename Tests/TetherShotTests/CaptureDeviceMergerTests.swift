import XCTest
@testable import TetherShot

final class CaptureDeviceMergerTests: XCTestCase {
    func testSameIPhoneOverUSBAndWiFiAppearsOnceAndPrefersUSB() {
        let udid = "00008110-001234567890001E"
        let avFoundationID = "2A8F2BF6-EE8C-4BD5-88D4-70B3A10B615B"
        let devices = [
            CaptureDevice(
                id: DeviceIdentity.iOS(rawID: udid),
                captureID: udid,
                name: "Apoorv’s iPhone",
                connection: .wireless
            ),
            CaptureDevice(
                id: DeviceIdentity.iOS(rawID: avFoundationID),
                captureID: avFoundationID,
                name: "Apoorv’s iPhone",
                connection: .usb
            ),
        ]

        let merged = CaptureDeviceMerger.merge(devices)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, DeviceIdentity.iOS(rawID: udid))
        XCTAssertEqual(merged[0].connection, .usb)
        XCTAssertEqual(merged[0].captureID, avFoundationID)
        XCTAssertEqual(merged[0].name, "Apoorv’s iPhone")
        XCTAssertEqual(merged[0].connectionSummary, "USB")
        XCTAssertEqual(merged[0].availableConnectionSummary, "USB + Wi-Fi")
        XCTAssertEqual(merged[0].availableConnections, [.usb, .wireless])
    }

    func testAmbiguousIPhoneNamesAreNotMerged() {
        let merged = CaptureDeviceMerger.merge([
            CaptureDevice(
                id: "ios:usb-one",
                captureID: "usb-one",
                name: "iPhone",
                connection: .usb
            ),
            CaptureDevice(
                id: "ios:usb-two",
                captureID: "usb-two",
                name: "iPhone",
                connection: .usb
            ),
            CaptureDevice(
                id: "ios:wifi-one",
                captureID: "wifi-one",
                name: "iPhone",
                connection: .wireless
            ),
        ])

        XCTAssertEqual(merged.count, 3)
    }

    func testFallbackIPhoneNameDoesNotMergeUnrelatedRoutes() {
        let merged = CaptureDeviceMerger.merge([
            CaptureDevice(
                id: "ios:usb",
                captureID: "usb",
                name: "iPhone …001E",
                connection: .usb
            ),
            CaptureDevice(
                id: "ios:wifi",
                captureID: "wifi",
                name: "iPhone …001E",
                connection: .wireless
            ),
        ])

        XCTAssertEqual(merged.count, 2)
    }

    func testAndroidIdentityUsesHardwareIDInsteadOfTransportSerial() {
        XCTAssertEqual(
            DeviceIdentity.android(androidID: "A1B2C3\n", adbSerial: "192.168.1.2:5555"),
            "android:a1b2c3"
        )
    }

    func testSamePhysicalAndroidOverUSBAndWiFiAppearsOnceAndPrefersUSB() {
        let stableID = "android:2b0ebf54c47846e6"
        let merged = CaptureDeviceMerger.merge([
            CaptureDevice(
                id: stableID,
                captureID: "10BE6L202X000AZ",
                name: "I2302",
                connection: .androidUSB
            ),
            CaptureDevice(
                id: stableID,
                captureID: "192.168.1.10:5555",
                name: "I2302",
                connection: .androidWireless
            ),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].captureID, "10BE6L202X000AZ")
        XCTAssertEqual(merged[0].connection, .androidUSB)
        XCTAssertEqual(merged[0].availableConnections, [.androidUSB, .androidWireless])
    }
}
