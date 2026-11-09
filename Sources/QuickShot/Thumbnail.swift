import AppKit
import QuickLookThumbnailing
import QuickShotCore
import SwiftUI

/// A thumbnail for a capture, made by the same system service Finder uses.
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
            } else {
                Image(systemName: item.kind == .image ? "photo" : "film")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.id) {
            image = await Self.thumbnail(for: item.url, scale: displayScale)
        }
    }

    private static func thumbnail(for url: URL, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 440, height: 330),
            scale: scale,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
