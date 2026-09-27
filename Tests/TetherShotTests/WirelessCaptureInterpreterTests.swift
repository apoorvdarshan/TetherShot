import XCTest
@testable import TetherShot

/// `pymobiledevice3` console scripts can be a direct python shebang, a
/// `#!/usr/bin/env python3` line, or pip's `#!/bin/sh` wrapper when the venv
/// path has spaces. The last one used to resolve to `/bin/sh`, which then ran
/// the helper with the wrong interpreter and silently fell back to the CLI.
final class WirelessCaptureInterpreterTests: XCTestCase {
    func testParsesQuotedWrapperInterpreter() throws {
        let python = try makeExecutable(named: "python")
        let wrapper = """
        #!/bin/sh
        '''exec' "\(python.path)" "$0" "$@"
        ' '''
        """
        XCTAssertEqual(WirelessCapture.wrapperInterpreter(in: wrapper), python.path)
    }

    func testParsesUnquotedWrapperInterpreter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let python = dir.appendingPathComponent("python3")
        try "#!/bin/sh\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: python.path
        )
        let wrapper = """
        #!/bin/sh
        '''exec' \(python.path) "$0" "$@"
        ' '''
        """
        XCTAssertEqual(WirelessCapture.wrapperInterpreter(in: wrapper), python.path)
    }

    func testReturnsNilForNonWrapperText() {
        XCTAssertNil(WirelessCapture.wrapperInterpreter(in: "import sys\nprint('hi')\n"))
    }

    func testRejectsWrapperPointingAtMissingInterpreter() {
        let wrapper = """
        #!/bin/sh
        '''exec' "/nope/missing/bin/python" "$0" "$@"
        ' '''
        """
        XCTAssertNil(WirelessCapture.wrapperInterpreter(in: wrapper))
    }

    private func makeExecutable(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}