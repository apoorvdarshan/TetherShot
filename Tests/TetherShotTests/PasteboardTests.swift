import AppKit
import XCTest
@testable import TetherShot

@MainActor
final class PasteboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("TetherShotTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func samplePNG(width: Int = 3, height: Int = 5) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testCopiesPNGUnchanged() throws {
        let png = try samplePNG()
        Pasteboard.copyPNG(png, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), png)
    }

    func testOffersTIFFAndBuildsItOnRequest() throws {
        let png = try samplePNG(width: 3, height: 5)
        Pasteboard.copyPNG(png, to: pasteboard)

        XCTAssertTrue(pasteboard.types?.contains(.tiff) == true)
        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertEqual(rep.pixelsWide, 3)
        XCTAssertEqual(rep.pixelsHigh, 5)
    }

    func testNewCopyReplacesPreviousImage() throws {
        Pasteboard.copyPNG(try samplePNG(width: 3, height: 5), to: pasteboard)
        Pasteboard.copyPNG(try samplePNG(width: 7, height: 2), to: pasteboard)

        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertEqual(rep.pixelsWide, 7)
        XCTAssertEqual(rep.pixelsHigh, 2)
    }
}
