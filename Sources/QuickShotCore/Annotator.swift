import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws numbered boxes around content in a screenshot, the way Groundwork's
/// gallery marks an element, and writes the result as a new PNG beside the
/// original. The original is never changed.
///
/// Boxes are given in unit coordinates of the picture (0…1, origin top left),
/// so the same boxes drawn on a scaled-down view and into the full-size file
/// land on the same content.
public enum Annotator {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAnImage
        case writeFailed

        public var description: String {
            switch self {
            case .notAnImage: "the file is not an image this Mac can read"
            case .writeFailed: "the marked picture could not be written"
            }
        }
    }

    // The look, in points. Groundwork: 3px #2b6cf0 border, 7px corners, a
    // 28px numbered badge with a 2px white border.
    public static let boxRed = 0x2B / 255.0, boxGreen = 0x6C / 255.0, boxBlue = 0xF0 / 255.0
    public static let strokeWidth: CGFloat = 3
    /// A white edge on both sides of the stroke, so the box reads on blue content.
    public static let haloWidth: CGFloat = 1
    public static let cornerRadius: CGFloat = 7
    public static let badgeDiameter: CGFloat = 28
    public static let badgeBorder: CGFloat = 2
    public static let badgeFontSize: CGFloat = 12
    /// A box with either edge under this many points is a slip of the mouse.
    public static let minimumEdge: CGFloat = 8

    static let boxColor = CGColor(srgbRed: boxRed, green: boxGreen, blue: boxBlue, alpha: 1)
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    public static let haloOpacity = 0.85
    static let halo = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: haloOpacity)

    /// Whether a file is a marked copy made here: `<name> (marked).png` or
    /// `<name> (marked 2).png`.
    public static func isMarked(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.range(of: #" \(marked( \d+)?\)$"#, options: .regularExpression) != nil
    }

    /// A picture read from disk, with its density.
    public struct Picture {
        public let image: CGImage
        /// Pixels per point: 2 for a Retina screenshot, 1 otherwise.
        public let scale: CGFloat
        public let dpi: Double

        public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
        public var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    }

    public static func load(_ source: URL) throws -> Picture {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else {
            throw Failure.notAnImage
        }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        return Picture(image: image, scale: max(1, (dpi / 72).rounded()), dpi: dpi)
    }

    /// Whether a box is large enough to mean something, in points.
    public static func isUsable(_ box: CGRect, in pointSize: CGSize) -> Bool {
        box.width * pointSize.width >= minimumEdge && box.height * pointSize.height >= minimumEdge
    }

    /// The picture with `boxes` drawn on it, numbered in order from 1.
    public static func render(_ picture: Picture, boxes: [CGRect]) throws -> CGImage {
        let image = picture.image
        let width = image.width, height = image.height
        // The picture's own colour space (Mac screenshots are Display P3), so
        // the pixels outside the boxes stay exactly as taken; sRGB for a
        // space a bitmap context cannot hold.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.writeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for (index, box) in boxes.enumerated() {
            let clamped = box.standardized.intersection(unit)
            guard !clamped.isNull, !clamped.isEmpty else { continue }
            draw(clamped, number: index + 1, in: context, picture: picture)
        }
        guard let marked = context.makeImage() else { throw Failure.writeFailed }
        return marked
    }

    private static func draw(_ box: CGRect, number: Int, in context: CGContext, picture: Picture) {
        let scale = picture.scale
        let size = picture.pixelSize
        // Unit coordinates have their origin at the top left; CoreGraphics at the bottom left.
        let rect = CGRect(
            x: box.minX * size.width, y: (1 - box.maxY) * size.height,
            width: box.width * size.width, height: box.height * size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale, transform: nil)
        context.setLineJoin(.round)
        context.addPath(path)
        context.setStrokeColor(halo)
        context.setLineWidth((strokeWidth + 2 * haloWidth) * scale)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(boxColor)
        context.setLineWidth(strokeWidth * scale)
        context.strokePath()

        // The badge sits on the box's top-left corner, over the stroke rather
        // than the content, and stays inside the picture.
        let outer = badgeDiameter * scale
        let centre = badgeCentre(for: rect, diameter: outer, in: size)
        context.setFillColor(white)
        context.fillEllipse(in: CGRect(x: centre.x - outer / 2, y: centre.y - outer / 2, width: outer, height: outer))
        let inner = outer - 2 * badgeBorder * scale
        context.setFillColor(boxColor)
        context.fillEllipse(in: CGRect(x: centre.x - inner / 2, y: centre.y - inner / 2, width: inner, height: inner))

        let font = boldSystemFont(size: badgeFontSize * scale)
        let text = NSAttributedString(string: String(number), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: centre.x - bounds.midX, y: centre.y - bounds.midY)
        CTLineDraw(line, context)
    }

    /// The badge's centre: the top-left corner of `rect` (CoreGraphics
    /// coordinates, origin bottom left), moved inward so the whole circle fits.
    public static func badgeCentre(for rect: CGRect, diameter: CGFloat, in size: CGSize) -> CGPoint {
        let half = diameter / 2
        return CGPoint(
            x: min(max(rect.minX, half), max(half, size.width - half)),
            y: min(max(rect.maxY, half), max(half, size.height - half)))
    }

    private static func boldSystemFont(size: CGFloat) -> CTFont {
        let regular = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .boldTrait, .boldTrait) ?? regular
    }

    /// PNG bytes of `image`, keeping the source's density so a Retina picture
    /// pastes at its true size.
    public static func pngData(_ image: CGImage, dpi: Double) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.writeFailed
        }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw Failure.writeFailed }
        return data as Data
    }

    /// Where the marked picture goes: `<name> (marked).png` beside the source,
    /// then `<name> (marked 2).png`, never over an existing file.
    public static func markedURL(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base) (marked).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (marked \(counter)).png")
            counter += 1
        }
        return candidate
    }

    /// Writes PNG bytes beside `source` under the marked name and returns
    /// the new file's location.
    public static func write(_ data: Data, beside source: URL) throws -> URL {
        let output = markedURL(for: source)
        do {
            try data.write(to: output, options: .withoutOverwriting)
        } catch {
            throw Failure.writeFailed
        }
        return output
    }

    /// Renders and writes in one step.
    public static func save(_ source: URL, boxes: [CGRect]) throws -> URL {
        let picture = try load(source)
        return try write(pngData(render(picture, boxes: boxes), dpi: picture.dpi), beside: source)
    }
}
