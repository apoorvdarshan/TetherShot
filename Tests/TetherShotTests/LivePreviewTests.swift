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

    func testLivePreviewUsesSubsecondRefreshThrottles() {
        for connection in [
            ConnectionKind.usb,
            .wireless,
            .androidUSB,
            .androidWireless,
        ] {
            XCTAssertLessThan(
                LivePreviewRefreshPolicy.intervalNanoseconds(for: connection),
                1_000_000_000
            )
        }
    }

    func testPreviewFrameTracksPortraitAndLandscapeAspectRatios() {
        XCTAssertEqual(
            LivePreviewAspectRatio.value(width: 1_179, height: 2_556),
            1_179.0 / 2_556.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LivePreviewAspectRatio.value(width: 2_556, height: 1_179),
            2_556.0 / 1_179.0,
            accuracy: 0.000_001
        )
    }

    func testPreviewFrameUsesPhoneFallbackForInvalidDimensions() {
        XCTAssertEqual(
            LivePreviewAspectRatio.value(width: 0, height: 0),
            LivePreviewAspectRatio.portraitFallback,
            accuracy: 0.000_001
        )
    }
}
