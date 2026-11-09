import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Halves a Retina screenshot to its size in points, so the file is about a
/// quarter of the size and still sharp enough to read, send or hand to an AI.
public enum ImageShrinker {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAnImage
        case writeFailed

        public var description: String {
            switch self {
            case .notAnImage: "the file is not an image this Mac can read"
            case .writeFailed: "the smaller image could not be written"
            }
        }
    }

    /// The pixel density above which an image is treated as Retina.
    public static let retinaDPI: Double = 100

    /// Writes the smaller PNG next to `source` as `<name>.1x.png` and returns
    /// it, or returns `source` itself when the image is already 1x or small.
    /// `source` is never changed.
    public static func shrink(_ source: URL) throws -> URL {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else {
            throw Failure.notAnImage
        }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        guard dpi >= retinaDPI, image.width >= 2, image.height >= 2 else { return source }

        let width = image.width / 2
        let height = image.height / 2
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.writeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { throw Failure.writeFailed }

        let output = source.deletingPathExtension().appendingPathExtension("1x").appendingPathExtension("png")
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.writeFailed
        }
        CGImageDestinationAddImage(writer, small, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.writeFailed
        }
        return output
    }
}
