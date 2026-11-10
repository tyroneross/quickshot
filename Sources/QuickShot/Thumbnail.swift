import AppKit
import QuickLookThumbnailing
import QuickShotCore
import SwiftUI

/// Small versions of images and movies, made once and kept. One loader for
/// captures and clipboard images: the work runs off the main actor and a
/// card that scrolls back into view gets its picture from the cache.
///
/// The key carries the file's size and date, so a capture replaced under the
/// same name gets a fresh picture; clipboard images are named by content and
/// never change.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()
    static let size = CGSize(width: 440, height: 330)

    static func key(for url: URL, byteCount: Int, modified: Date) -> NSString {
        "\(url.path)|\(byteCount)|\(modified.timeIntervalSinceReferenceDate)" as NSString
    }

    static func cached(for url: URL, byteCount: Int, modified: Date) -> NSImage? {
        cache.object(forKey: key(for: url, byteCount: byteCount, modified: modified))
    }

    /// The picture, from the cache or made now by the same service Finder
    /// uses (which handles movies as well as images).
    static func image(for url: URL, byteCount: Int, modified: Date, scale: CGFloat) async -> NSImage? {
        let key = key(for: url, byteCount: byteCount, modified: modified)
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage else { return nil }
        cache.setObject(made, forKey: key)
        return made
    }

    /// For tests and for the clipboard rows: the file's own size and date.
    static func image(for url: URL, scale: CGFloat) async -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return await image(for: url, byteCount: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast, scale: scale)
    }
}

/// A thumbnail for a capture.
struct ThumbnailView: View {
    let item: CaptureItem
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .accessibilityHidden(true)
                        .font(.largeTitle)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
            } else {
                Image(systemName: item.kind == .image ? "photo" : "film")
                    .accessibilityHidden(true)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.id) {
            // A cached picture shows at once, without a blank frame.
            if let hit = Thumbnails.cached(for: item.url, byteCount: item.byteCount, modified: item.created) {
                image = hit
            } else {
                image = await Thumbnails.image(for: item.url, byteCount: item.byteCount, modified: item.created, scale: displayScale)
            }
        }
    }
}

/// A thumbnail for a clipboard image, by its file.
struct FileThumbnailView: View {
    let url: URL
    let placeholder: AnyView
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) { image = await Thumbnails.image(for: url, scale: displayScale) }
    }
}
