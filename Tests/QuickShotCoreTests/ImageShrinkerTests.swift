import CoreGraphics
import Foundation
import ImageIO
import Testing
import TestSupport
import UniformTypeIdentifiers
@testable import QuickShotCore

@Suite struct ImageShrinkerTests {
    /// Writes a PNG with the given pixel size and DPI, as the system tool does
    /// for a Retina (144 DPI) or a plain (72 DPI) screen.
    static func makePNG(at url: URL, width: Int, height: Int, dpi: Double) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
    }

    static func size(of url: URL) throws -> (Int, Int, Double) {
        let reader = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int,
                properties[kCGImagePropertyDPIWidth] as? Double ?? 72)
    }

    @Test func aRetinaScreenshotIsHalvedAndTheSourceStays() throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.png")
        try Self.makePNG(at: source, width: 800, height: 600, dpi: 144)

        let small = try ImageShrinker.shrink(source)

        #expect(small.lastPathComponent == "capture.1x.png")
        #expect(try Self.size(of: small) == (400, 300, 72))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(CaptureFormat.detect(small) == .png)
    }

    @Test func aPlainScreenshotIsReturnedAsIs() throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.png")
        try Self.makePNG(at: source, width: 800, height: 600, dpi: 72)
        #expect(try ImageShrinker.shrink(source) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["capture.png"])
    }

    @Test func aFileThatIsNotAnImageIsRefused() throws {
        let folder = try TempFolder()
        let text = folder.url.appendingPathComponent("notes.png")
        try Data(Fixture.text).write(to: text)
        #expect(throws: ImageShrinker.Failure.notAnImage) { try ImageShrinker.shrink(text) }
    }
}
