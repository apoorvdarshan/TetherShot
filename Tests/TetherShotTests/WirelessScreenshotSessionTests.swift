import XCTest
@testable import TetherShot

final class WirelessScreenshotSessionTests: XCTestCase {
    private var helperURL: URL!

    override func setUpWithError() throws {
        helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-wireless-helper-\(UUID().uuidString).sh")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: helperURL)
    }

    /// Stands in for scripts/wireless-screenshot.py using the same framing.
    private func session(helper script: String) throws -> WirelessScreenshotSession {
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        return WirelessScreenshotSession(pythonPath: "/bin/sh", helperPath: helperURL.path)
    }

    func testReturnsPayloadAndReusesHelper() async throws {
        let session = try session(helper: """
        while read command udid; do
          printf 'P\\000\\000\\000\\003'
          printf '%s' "$udid" | cut -c1-3 | tr -d '\\n'
        done
        """)

        let first = try await session.capture(deviceID: "abc-1")
        let second = try await session.capture(deviceID: "xyz-2")

        XCTAssertEqual(String(decoding: first, as: UTF8.self), "abc")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "xyz")
    }

    func testSurfacesHelperErrorMessage() async throws {
        let session = try session(helper: """
        while read command udid; do
          printf 'E\\000\\000\\000\\011no tunnel'
        done
        """)

        do {
            _ = try await session.capture(deviceID: "abc")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no tunnel")
        }
    }

    func testStartsNewHelperAfterOneDies() async throws {
        // The first helper exits without replying; any later one answers.
        let marker = helperURL.appendingPathExtension("started")
        defer { try? FileManager.default.removeItem(at: marker) }
        let session = try session(helper: """
        if [ ! -e '\(marker.path)' ]; then
          touch '\(marker.path)'
          exit 1
        fi
        while read command udid; do
          printf 'P\\000\\000\\000\\002ok'
        done
        """)

        do {
            _ = try await session.capture(deviceID: "a")
            XCTFail("Expected the first helper to fail")
        } catch {}

        let png = try await session.capture(deviceID: "a")
        XCTAssertEqual(String(decoding: png, as: UTF8.self), "ok")
    }

    func testCloseUsesTheSameFraming() async throws {
        // A close must consume a reply like any other command, otherwise the
        // next capture reads the close's reply as its own.
        let session = try session(helper: """
        while read command udid; do
          if [ "$command" = "close" ]; then
            printf 'K\\000\\000\\000\\000'
          else
            printf 'P\\000\\000\\000\\002ok'
          fi
        done
        """)

        session.close(deviceID: "gone")
        let png = try await session.capture(deviceID: "still-here")
        XCTAssertEqual(String(decoding: png, as: UTF8.self), "ok")
    }
}
