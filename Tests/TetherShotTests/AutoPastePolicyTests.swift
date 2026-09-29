import XCTest
@testable import TetherShot

final class AutoPastePolicyTests: XCTestCase {
    func testPastesHotKeyCaptureIntoAnotherApp() {
        XCTAssertTrue(AutoPastePolicy.shouldPaste(
            enabled: true, copiedToClipboard: true, fromHotKey: true, frontmostIsTetherShot: false
        ))
    }

    func testDoesNotPasteWhenTurnedOff() {
        XCTAssertFalse(AutoPastePolicy.shouldPaste(
            enabled: false, copiedToClipboard: true, fromHotKey: true, frontmostIsTetherShot: false
        ))
    }

    func testDoesNotPasteWithoutClipboardCopy() {
        XCTAssertFalse(AutoPastePolicy.shouldPaste(
            enabled: true, copiedToClipboard: false, fromHotKey: true, frontmostIsTetherShot: false
        ))
    }

    func testDoesNotPasteCapturesStartedFromTheWindow() {
        XCTAssertFalse(AutoPastePolicy.shouldPaste(
            enabled: true, copiedToClipboard: true, fromHotKey: false, frontmostIsTetherShot: false
        ))
    }

    func testDoesNotPasteIntoTetherShotItself() {
        XCTAssertFalse(AutoPastePolicy.shouldPaste(
            enabled: true, copiedToClipboard: true, fromHotKey: true, frontmostIsTetherShot: true
        ))
    }
}
