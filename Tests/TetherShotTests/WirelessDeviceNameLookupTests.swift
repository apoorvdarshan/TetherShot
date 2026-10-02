import XCTest
@testable import TetherShot

final class WirelessDeviceNameLookupTests: XCTestCase {
    func testResolvesWiFiPhoneAbsentFromUSBDiscovery() async {
        let names = await WirelessDeviceNameLookup.resolve(
            pmd3Path: "/mock/pmd3", tunneledDeviceIDs: ["wifi-phone"]
        ) { path, arguments, _ in
            XCTAssertEqual(path, "/mock/pmd3")
            if arguments == ["usbmux", "list"] {
                return Proc.Result(status: 0, stdout: "[]", stderr: "")
            }
            XCTAssertEqual(arguments, ["lockdown", "device-name", "--tunnel", "wifi-phone"])
            return Proc.Result(status: 0, stdout: "Apoorv’s iPhone\n", stderr: "")
        }
        XCTAssertEqual(names["wifi-phone"], "Apoorv’s iPhone")
    }

    func testKeepsUSBNameAndOnlyQueriesMissingPhones() async {
        let names = await WirelessDeviceNameLookup.resolve(
            pmd3Path: "/mock/pmd3", tunneledDeviceIDs: ["usb-phone", "wifi-phone", "wifi-phone"]
        ) { _, arguments, _ in
            if arguments == ["usbmux", "list"] {
                return Proc.Result(status: 0, stdout: """
                [{"Identifier":"usb-phone","DeviceName":"USB iPhone"}]
                """, stderr: "")
            }
            XCTAssertEqual(arguments, ["lockdown", "device-name", "--tunnel", "wifi-phone"])
            return Proc.Result(status: 0, stdout: "Wi-Fi iPhone\n", stderr: "")
        }
        XCTAssertEqual(names, ["usb-phone": "USB iPhone", "wifi-phone": "Wi-Fi iPhone"])
    }

    func testStillQueriesTunnelWhenUSBDiscoveryFails() async {
        let names = await WirelessDeviceNameLookup.resolve(
            pmd3Path: "/mock/pmd3", tunneledDeviceIDs: ["wifi-phone"]
        ) { _, arguments, _ in
            if arguments == ["usbmux", "list"] {
                return Proc.Result(status: 1, stdout: "", stderr: "usbmux unavailable")
            }
            return Proc.Result(status: 0, stdout: "Apoorv’s iPhone", stderr: "")
        }
        XCTAssertEqual(names["wifi-phone"], "Apoorv’s iPhone")
    }

    func testDoesNotTreatFailedOrEmptyLookupAsADeviceName() async {
        let names = await WirelessDeviceNameLookup.resolve(
            pmd3Path: "/mock/pmd3", tunneledDeviceIDs: ["failed", "empty", "invalid"]
        ) { _, arguments, _ in
            if arguments == ["usbmux", "list"] {
                return Proc.Result(status: 0, stdout: "[]", stderr: "")
            }
            switch arguments.last {
            case "failed": return Proc.Result(status: 1, stdout: "Error", stderr: "Disconnected")
            case "empty": return Proc.Result(status: 0, stdout: " \n", stderr: "")
            default: return Proc.Result(status: 0, stdout: "Usage:\nCommand help", stderr: "")
            }
        }
        XCTAssertTrue(names.isEmpty)
    }
}
