import XCTest
@testable import TetherShot

final class LivePreviewTests: XCTestCase {
    func testUSBRefreshesMoreFrequentlyThanWireless() {
        XCTAssertLessThan(
            LivePreviewRefreshPolicy.intervalNanoseconds(for: .usb),
            LivePreviewRefreshPolicy.intervalNanoseconds(for: .wireless)
        )
    }

    func testCachedFrameAgeCoversARefreshCycle() {
        let usbInterval = Double(LivePreviewRefreshPolicy.intervalNanoseconds(for: .usb)) / 1_000_000_000
        let wirelessInterval = Double(LivePreviewRefreshPolicy.intervalNanoseconds(for: .wireless)) / 1_000_000_000

        XCTAssertGreaterThan(LivePreviewRefreshPolicy.maximumFrameAge(for: .usb), usbInterval)
        XCTAssertGreaterThan(LivePreviewRefreshPolicy.maximumFrameAge(for: .wireless), wirelessInterval)
    }
}
