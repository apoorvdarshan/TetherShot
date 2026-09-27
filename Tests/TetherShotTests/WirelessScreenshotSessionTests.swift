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

    func testWarmIsSentOncePerDevice() async throws {
        // Repeated discovery passes call warm again; the session should drop the
        // duplicates instead of queueing more work ahead of a capture. The
        // helper records each warm it sees.
        let log = helperURL.appendingPathExtension("warm-log")
        defer { try? FileManager.default.removeItem(at: log) }
        let session = try session(helper: """
        while read command udid; do
          if [ "$command" = "warm" ]; then
            echo "$udid" >> '\(log.path)'
          fi
          printf 'K\\000\\000\\000\\000'
        done
        """)

        session.warm(deviceID: "abc")
        session.warm(deviceID: "abc")
        session.warm(deviceID: "abc")
        _ = try await session.capture(deviceID: "abc")

        let seen = (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).count ?? 0
        XCTAssertEqual(seen, 1, "warm should be sent once per device")
    }

    func testWarmIsRetriedAfterFailure() async throws {
        // A warm that fails must clear its state, or the device would never be
        // warmed again. The fake helper fails warm once, then records.
        let marker = helperURL.appendingPathExtension("failed-once")
        let log = helperURL.appendingPathExtension("warm-log")
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: log)
        }
        let session = try session(helper: """
        while read command udid; do
          if [ "$command" = "warm" ] && [ ! -e '\(marker.path)' ]; then
            touch '\(marker.path)'
            printf 'E\\000\\000\\000\\004boom'
          else
            if [ "$command" = "warm" ]; then echo "$udid" >> '\(log.path)'; fi
            printf 'K\\000\\000\\000\\000'
          fi
        done
        """)

        session.warm(deviceID: "abc")
        _ = try await session.capture(deviceID: "tick")   // flush the failed warm
        session.warm(deviceID: "abc")
        _ = try await session.capture(deviceID: "tick")

        let seen = (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).count ?? 0
        XCTAssertEqual(seen, 1, "a failed warm should be retried")
    }

    func testForgetAllowsRewarm() async throws {
        // A device that goes away and returns must warm again.
        let log = helperURL.appendingPathExtension("warm-log")
        defer { try? FileManager.default.removeItem(at: log) }
        let session = try session(helper: """
        while read command udid; do
          if [ "$command" = "warm" ]; then echo "$udid" >> '\(log.path)'; fi
          printf 'K\\000\\000\\000\\000'
        done
        """)

        session.warm(deviceID: "abc")
        _ = try await session.capture(deviceID: "tick")
        session.forget(deviceID: "abc")
        session.warm(deviceID: "abc")
        _ = try await session.capture(deviceID: "tick")

        let seen = (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).count ?? 0
        XCTAssertEqual(seen, 2, "a forgotten device should warm again")
    }
}
