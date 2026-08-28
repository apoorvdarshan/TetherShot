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

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0], CaptureDevice(id: "R5CT123456", captureID: "R5CT123456", name: "SM S918B", connection: .android))
        XCTAssertEqual(devices[1], CaptureDevice(id: "emulator-5554", captureID: "emulator-5554", name: "Pixel 8 Pro", connection: .android))
    }
}
