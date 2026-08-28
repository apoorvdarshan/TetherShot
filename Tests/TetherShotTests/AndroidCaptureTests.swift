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

    func testAnnexBParserDeliversCompleteNALUnitsAcrossChunks() {
        var parser = AnnexBNALParser()

        XCTAssertTrue(parser.append(Data([0, 0, 0, 1, 0x67, 0x01])).isEmpty)
        XCTAssertEqual(
            parser.append(Data([0, 0, 1, 0x68, 0x02, 0, 0])),
            [Data([0x67, 0x01])]
        )
        XCTAssertEqual(
            parser.append(Data([1, 0x65, 0x03, 0x04])),
            [Data([0x68, 0x02])]
        )
        XCTAssertEqual(parser.finish(), [Data([0x65, 0x03, 0x04])])
    }
}
