import XCTest
@testable import TetherShot

final class UpdaterTests: XCTestCase {
    @MainActor
    func testSemanticVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "1.0.0-beta.1"))
        XCTAssertFalse(Updater.isNewer("1.0.0-beta.1", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
    }

    func testOnlyCanonicalApplicationLocationsAreSupported() {
        XCTAssertTrue(AppInstallation.isSupportedInstallLocation(AppInstallation.systemApp))
        XCTAssertTrue(AppInstallation.isSupportedInstallLocation(AppInstallation.userApp))
        XCTAssertFalse(AppInstallation.isSupportedInstallLocation(URL(fileURLWithPath: "/tmp/TetherShot.app")))
    }
}
