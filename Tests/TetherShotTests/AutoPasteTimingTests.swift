import XCTest
import ApplicationServices
@testable import TetherShot

@MainActor
final class AutoPasteTimingTests: XCTestCase {
    func testMissingAccessibilityFocusDoesNotBlockPaste() async {
        var posted = false
        let result = await AutoPaste.pasteValidated(
            access: { true }, waitForRelease: { true },
            contextMatches: { AutoPaste.focusMatches(original: nil, current: nil) },
            post: { posted = true; return true }
        )
        XCTAssertEqual(result, .posted)
        XCTAssertTrue(posted)
    }

    func testExistingFocusStillRequiresSameElement() {
        let original = AXUIElementCreateApplication(123)
        XCTAssertTrue(AutoPaste.focusMatches(original: original, current: AXUIElementCreateApplication(123)))
        XCTAssertFalse(AutoPaste.focusMatches(original: original, current: AXUIElementCreateApplication(456)))
        XCTAssertFalse(AutoPaste.focusMatches(original: original, current: nil))
    }

    func testChangedDestinationDuringWaitSkipsPosting() async {
        var destination = 1
        var posted = false
        let result = await AutoPaste.pasteValidated(
            access: { true }, waitForRelease: { destination = 2; return true },
            contextMatches: { destination == 1 }, post: { posted = true; return true }
        )
        XCTAssertEqual(result, .skipped)
        XCTAssertFalse(posted)
    }

    func testClipboardReplacementDuringWaitSkipsPosting() async {
        var changeCount = 10
        var posted = false
        let result = await AutoPaste.pasteValidated(
            access: { true }, waitForRelease: { changeCount += 1; return true },
            contextMatches: { changeCount == 10 }, post: { posted = true; return true }
        )
        XCTAssertEqual(result, .skipped)
        XCTAssertFalse(posted)
    }

    func testUnchangedContextPostsOnce() async {
        var posts = 0
        let result = await AutoPaste.pasteValidated(
            access: { true }, waitForRelease: { true }, contextMatches: { true },
            post: { posts += 1; return true }
        )
        XCTAssertEqual(result, .posted)
        XCTAssertEqual(posts, 1)
    }

    func testHeldModifiersSkipWithoutPermissionError() async {
        let result = await AutoPaste.pasteValidated(
            access: { true }, waitForRelease: { false }, contextMatches: { true },
            post: { XCTFail("Should not post"); return true }
        )
        XCTAssertEqual(result, .skipped)
    }

    func testMissingAccessDoesNotWaitOrPost() async {
        let result = await AutoPaste.pasteValidated(
            access: { false }, waitForRelease: { XCTFail("Should not wait"); return true },
            contextMatches: { true }, post: { XCTFail("Should not post"); return true }
        )
        XCTAssertEqual(result, .needsAccess)
    }
}
