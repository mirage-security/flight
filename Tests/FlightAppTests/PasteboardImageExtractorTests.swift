import AppKit
import XCTest
@testable import FlightApp

final class PasteboardImageExtractorTests: XCTestCase {
    func testExtractsPublicPNGFromPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        let pngData = try makePNGData()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))

        let attachment = try XCTUnwrap(PasteboardImageExtractor.imageAttachment(from: pasteboard))

        XCTAssertFalse(attachment.pngData.isEmpty)
        XCTAssertNotNil(NSImage(data: attachment.pngData))
    }

    func testExtractsLegacyScreenshotPNGTypeFromPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        let pngData = try makePNGData()
        XCTAssertTrue(pasteboard.setData(
            pngData,
            forType: NSPasteboard.PasteboardType("Apple PNG pasteboard type")
        ))

        let attachment = try XCTUnwrap(PasteboardImageExtractor.imageAttachment(from: pasteboard))

        XCTAssertFalse(attachment.pngData.isEmpty)
        XCTAssertNotNil(NSImage(data: attachment.pngData))
    }

    private func makePNGData() throws -> Data {
        let pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
