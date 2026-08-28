import XCTest
@testable import TetherShot

final class PreviewActivityPolicyTests: XCTestCase {
    func testWindowMustBeVisibleAndUnobscured() {
        XCTAssertTrue(PreviewActivityPolicy.windowAllowsPreview(
            isVisible: true,
            isMiniaturized: false,
            occlusionIsVisible: true,
            appIsHidden: false
        ))
        XCTAssertFalse(PreviewActivityPolicy.windowAllowsPreview(
            isVisible: true,
            isMiniaturized: true,
            occlusionIsVisible: true,
            appIsHidden: false
        ))
        XCTAssertFalse(PreviewActivityPolicy.windowAllowsPreview(
            isVisible: true,
            isMiniaturized: false,
            occlusionIsVisible: false,
            appIsHidden: false
        ))
        XCTAssertFalse(PreviewActivityPolicy.windowAllowsPreview(
            isVisible: true,
            isMiniaturized: false,
            occlusionIsVisible: true,
            appIsHidden: true
        ))
    }

    func testPreviewRunsOnlyWhenEnabledWindowAndPageAreVisible() {
        XCTAssertTrue(PreviewActivityPolicy.shouldRun(
            previewsEnabled: true,
            windowIsVisible: true,
            previewPageIsVisible: true
        ))
        XCTAssertFalse(PreviewActivityPolicy.shouldRun(
            previewsEnabled: false,
            windowIsVisible: true,
            previewPageIsVisible: true
        ))
        XCTAssertFalse(PreviewActivityPolicy.shouldRun(
            previewsEnabled: true,
            windowIsVisible: false,
            previewPageIsVisible: true
        ))
        XCTAssertFalse(PreviewActivityPolicy.shouldRun(
            previewsEnabled: true,
            windowIsVisible: true,
            previewPageIsVisible: false
        ))
    }
}
