import XCTest
@testable import TetherShot

final class AndroidCaptureTests: XCTestCase {
    func testParsesAuthorizedADBDevicesAndFriendlyModelNames() {
        let output = """
        List of devices attached
        R5CT123456 device usb:1-1 product:dm3q model:SM_S918B device:dm3q transport_id:1
        emulator-5554 device product:sdk model:Pixel_8_Pro device:emu transport_id:2
        WAITING unauthorized usb:1-2 transport_id:3

        """

        let devices = AndroidDeviceParser.parse(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0], CaptureDevice(id: "R5CT123456", captureID: "R5CT123456", name: "SM S918B", connection: .androidUSB))
    }

    func testIdentifiesWirelessADBAndFiltersEmulatorMetadata() {
        let output = """
        List of devices attached
        192.168.1.10:5555 device product:I2302 model:I2302 device:I2302 transport_id:1
        local-emulator device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:2

        """

        let devices = AndroidDeviceParser.parse(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].connection, .androidWireless)
        XCTAssertTrue(AndroidDeviceParser.isEmulator(kernelQEMU: "1\n", bootQEMU: ""))
        XCTAssertFalse(AndroidDeviceParser.isEmulator(kernelQEMU: "\n", bootQEMU: "0\n"))
    }

    func testParsesWirelessADBSerialWithBonjourConflictSuffix() {
        let serial = "adb-10BE6L202X000AZ-v1VF8w (2)._adb-tls-connect._tcp"
        let output = """
        List of devices attached
        \(serial) device product:I2302T model:I2302 device:I2302 transport_id:1

        """

        let devices = AndroidDeviceParser.parse(output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].captureID, serial)
        XCTAssertEqual(devices[0].name, "I2302")
        XCTAssertEqual(devices[0].connection, .androidWireless)
    }

    func testResolvesChangedBonjourConflictSuffixForSameWirelessDevice() {
        let requested = "adb-10BE6L202X000AZ-v1VF8w (2)._adb-tls-connect._tcp"
        let current = "adb-10BE6L202X000AZ-v1VF8w (3)._adb-tls-connect._tcp"
        let candidates = [CaptureDevice(
            id: current,
            captureID: current,
            name: "I2302",
            connection: .androidWireless
        )]

        XCTAssertEqual(
            AndroidDeviceParser.matchingSerials(requested: requested, candidates: candidates),
            [current]
        )
        XCTAssertEqual(
            AndroidDeviceParser.stableSerial(requested),
            "adb-10BE6L202X000AZ-v1VF8w._adb-tls-connect._tcp"
        )
    }

    func testDuplicateBonjourRoutesPreferResponsiveAliasAndKeepOtherPhonesSeparate() {
        let first = "adb-LAVA1-guid._adb-tls-connect._tcp"
        let second = "adb-LAVA1-guid (2)._adb-tls-connect._tcp"
        let other = "adb-LAVA2-guid._adb-tls-connect._tcp"
        let devices = CaptureDeviceMerger.merge(AndroidDeviceParser.reconcile([
            route(first),
            route(second, androidID: "AB12\n"),
            route(other),
        ]))

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?.id, "android:ab12")
        XCTAssertEqual(devices.first?.captureID, second)
        XCTAssertTrue(devices.contains { $0.captureID == other })
    }

    func testUnresponsiveAliasesRemainOneDeviceAndRetryListStartsWithRequestedRoute() {
        let first = "adb-LAVA1-guid._adb-tls-connect._tcp"
        let second = "adb-LAVA1-guid (2)._adb-tls-connect._tcp"
        let third = "adb-LAVA1-guid (3)._adb-tls-connect._tcp"
        let other = "adb-LAVA2-guid._adb-tls-connect._tcp"
        let routes = [route(second), route(first), route(other), route(third)]

        XCTAssertEqual(CaptureDeviceMerger.merge(AndroidDeviceParser.reconcile(routes)).count, 2)
        XCTAssertEqual(
            AndroidDeviceParser.matchingSerials(requested: first, candidates: routes.map(\.device)),
            [first, second, third]
        )
    }

    func testCachedIdentitySurvivesTimeoutButIsNeverReusedForAnIPAddress() async {
        let cache = AndroidRouteIdentityCache()
        let first = "adb-LAVA1-guid._adb-tls-connect._tcp"
        let second = "adb-LAVA1-guid (2)._adb-tls-connect._tcp"
        let address = "192.168.1.10:36115"
        _ = await cache.reconcile([route(first, androidID: "ab12"), route(address, androidID: "ab12")])
        let refreshed = await cache.reconcile([route(second), route(address)])

        XCTAssertEqual(refreshed[0].id, "android:ab12")
        XCTAssertEqual(refreshed[1].id, "android-adb:\(address)")
    }

    func testConflictingVerifiedIdentitiesAreNotMerged() {
        let first = "adb-LAVA1-guid._adb-tls-connect._tcp"
        let second = "adb-LAVA1-guid (2)._adb-tls-connect._tcp"
        let devices = CaptureDeviceMerger.merge(AndroidDeviceParser.reconcile([
            route(first, androidID: "ab12"),
            route(second, androidID: "ab34"),
        ]))

        XCTAssertEqual(devices.map(\.id), ["android:ab12", "android:ab34"])
    }

    private func route(_ serial: String, androidID: String? = nil) -> AndroidDeviceParser.Route {
        .init(device: CaptureDevice(id: serial, name: "LAVA LZG411", connection: .androidWireless), androidID: androidID)
    }
}
