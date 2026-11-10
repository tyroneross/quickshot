import CoreGraphics
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import QuickShotCore

@Suite struct AnnotatorTests {
    /// One pixel of a picture, as sRGB components, with `y` counted from the top.
    static func pixel(of image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    static func isBoxBlue(_ p: (r: Double, g: Double, b: Double)) -> Bool {
        abs(p.r - Annotator.boxRed) < 0.08 && abs(p.g - Annotator.boxGreen) < 0.08 && abs(p.b - Annotator.boxBlue) < 0.08
    }

    /// Every pixel, so two renders can be compared exactly.
    static func bytes(of image: CGImage) throws -> Data {
        var data = Data(count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    static let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    /// A pale picture, so the box colour cannot be mistaken for the content.
    /// (The shrinker fixture is a blue close to the box blue.)
    static func makePalePNG(at url: URL, width: Int, height: Int, dpi: Double) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        try Data(Annotator.pngData(image, dpi: dpi)).write(to: url)
    }

    @Test func boxesAreDrawnAtFullSizeAndTheSourceStays() throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("Screenshot 2026-11-09 at 17.00.00.png")
        try Self.makePalePNG(at: source, width: 800, height: 600, dpi: 144)
        let before = try Data(contentsOf: source)

        let marked = try Annotator.save(source, boxes: [Self.box])

        #expect(marked.lastPathComponent == "Screenshot 2026-11-09 at 17.00.00 (marked).png")
        #expect(Annotator.isMarked(marked) && !Annotator.isMarked(source))
        #expect(try Data(contentsOf: source) == before, "the original was changed")
        #expect(try ImageShrinkerTests.size(of: marked) == (800, 600, 144), "size or density changed")
        #expect(CaptureFormat.detect(marked) == .png)

        let picture = try Annotator.load(marked)
        // The left edge of the box is at x = 200 px; the stroke is 6 px wide at 2x.
        #expect(Self.isBoxBlue(try Self.pixel(of: picture.image, x: 200, y: 300)), "no box stroke on the left edge")
        #expect(Self.isBoxBlue(try Self.pixel(of: picture.image, x: 400, y: 150)), "no box stroke on the top edge")
        // Inside and outside the box the picture is as it was (the fixture is one colour).
        let inside = try Self.pixel(of: picture.image, x: 400, y: 300)
        let outside = try Self.pixel(of: picture.image, x: 40, y: 560)
        #expect(!Self.isBoxBlue(inside) && abs(inside.r - 0.9) < 0.05)
        #expect(abs(outside.r - inside.r) < 0.02 && abs(outside.b - inside.b) < 0.02)
    }

    @Test func noBoxesGivesTheSamePicture() throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.png")
        try ImageShrinkerTests.makePNG(at: source, width: 120, height: 80, dpi: 72)
        let picture = try Annotator.load(source)
        #expect(try Self.bytes(of: Annotator.render(picture, boxes: [])) == Self.bytes(of: picture.image))
    }

    @Test func boxesOutsideThePictureAreClampedNotDropped() throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.png")
        try ImageShrinkerTests.makePNG(at: source, width: 200, height: 100, dpi: 72)
        let picture = try Annotator.load(source)
        // Half the box hangs off the right edge; its left edge at x = 100 is still drawn.
        let image = try Annotator.render(picture, boxes: [CGRect(x: 0.5, y: 0.2, width: 0.9, height: 0.6)])
        #expect(Self.isBoxBlue(try Self.pixel(of: image, x: 100, y: 50)))
        // A box entirely outside draws nothing.
        let untouched = try Annotator.render(picture, boxes: [CGRect(x: 1.5, y: 0, width: 0.5, height: 0.5)])
        #expect(try Self.bytes(of: untouched) == Self.bytes(of: picture.image))
    }

    @Test func aSecondMarkedPictureNeverOverwritesTheFirst() throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.png")
        try ImageShrinkerTests.makePNG(at: source, width: 60, height: 40, dpi: 72)
        let first = try Annotator.save(source, boxes: [Self.box])
        let second = try Annotator.save(source, boxes: [])
        #expect(first.lastPathComponent == "capture (marked).png")
        #expect(second.lastPathComponent == "capture (marked 2).png")
        #expect(Annotator.isMarked(second))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
                == ["capture (marked 2).png", "capture (marked).png", "capture.png"])
    }

    @Test func theBadgeStaysInsideThePicture() {
        let size = CGSize(width: 400, height: 300)
        // A box at the very top-left corner: the badge moves in by its radius.
        #expect(Annotator.badgeCentre(for: CGRect(x: 0, y: 200, width: 100, height: 100), diameter: 28, in: size) == CGPoint(x: 14, y: 286))
        // A box well inside: the badge sits on the corner.
        #expect(Annotator.badgeCentre(for: CGRect(x: 100, y: 100, width: 100, height: 100), diameter: 28, in: size) == CGPoint(x: 100, y: 200))
    }

    @Test func tinyBoxesAreNotUsable() {
        let size = CGSize(width: 1000, height: 500)
        #expect(!Annotator.isUsable(CGRect(x: 0, y: 0, width: 0.007, height: 0.5), in: size), "7 pt wide")
        #expect(Annotator.isUsable(CGRect(x: 0, y: 0, width: 0.008, height: 0.016), in: size), "8 pt by 8 pt")
    }

    @Test func aFileThatIsNotAnImageIsRefused() throws {
        let folder = try TempFolder()
        let text = folder.url.appendingPathComponent("notes.png")
        try Data(Fixture.text).write(to: text)
        #expect(throws: Annotator.Failure.notAnImage) { try Annotator.save(text, boxes: []) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["notes.png"])
    }
}
