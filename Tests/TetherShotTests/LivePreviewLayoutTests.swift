import XCTest
@testable import TetherShot

final class LivePreviewLayoutTests: XCTestCase {
    func testNarrowWindowUsesSingleSelectedPreview() {
        XCTAssertEqual(
            LivePreviewLayoutPolicy.columnCount(availableWidth: 700, deviceCount: 3),
            1
        )
    }

    func testNormalWindowShowsTwoDevicesSideBySide() {
        XCTAssertEqual(
            LivePreviewLayoutPolicy.columnCount(availableWidth: 810, deviceCount: 2),
            2
        )
    }

    func testLargeWindowFitsThreeDevicesAndCapsTheGrid() {
        XCTAssertEqual(
            LivePreviewLayoutPolicy.columnCount(availableWidth: 1_140, deviceCount: 3),
            3
        )
        XCTAssertEqual(
            LivePreviewLayoutPolicy.columnCount(availableWidth: 1_600, deviceCount: 5),
            3
        )
    }

    func testGridTilesKeepAUsableMinimumHeight() {
        XCTAssertGreaterThanOrEqual(
            LivePreviewLayoutPolicy.tileHeight(
                availableHeight: 600,
                deviceCount: 6,
                columnCount: 3
            ),
            360
        )
    }
}
