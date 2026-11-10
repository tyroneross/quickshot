import AVFoundation
import Foundation

/// Re-encodes a recording to 1080p HEVC so it is small enough to attach to a
/// bug report or hand to an AI. The system recorder has no quality setting of
/// its own: it always writes the display's native resolution.
public enum MovieShrinker {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAMovie
        case exportFailed(String)

        public var description: String {
            switch self {
            case .notAMovie: "the file is not a movie this Mac can read"
            case .exportFailed(let reason): reason
            }
        }
    }

    public static let presetName = AVAssetExportPresetHEVC1920x1080
    /// The longest edge a Quick movie keeps.
    public static let maxEdge: CGFloat = 1920

    /// `size` scaled down to fit the Quick limit, keeping its proportions;
    /// unchanged when it already fits.
    public static func fitted(_ size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return size }
        let factor = maxEdge / longest
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    /// Whether a movie already fits the Quick limit, so no export is needed.
    public static func alreadyFits(_ source: URL) async -> Bool {
        guard let track = try? await AVURLAsset(url: source).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return false }
        return max(size.width, size.height) <= maxEdge
    }

    /// Writes the shrunk movie next to `source` as `<name>-1080p.mp4`, and
    /// returns its location. `source` is never changed: the caller decides
    /// which file to keep, so a failed export loses nothing.
    public static func shrink(_ source: URL) async throws -> URL {
        // A movie recorded at the Quick size already is kept as it is.
        if await alreadyFits(source) { return source }
        let asset = AVURLAsset(url: source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            throw Failure.notAMovie
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw Failure.exportFailed("this Mac cannot export \(presetName)")
        }
        let output = source.deletingPathExtension()
            .appendingPathExtension("1080p")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure.exportFailed(error.localizedDescription)
        }
        return output
    }
}
