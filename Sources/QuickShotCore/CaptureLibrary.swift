import Foundation

/// One capture on disk.
public struct CaptureItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let kind: CaptureKind
    public let created: Date
    public let byteCount: Int

    public var id: URL { url }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The captures folder. The folder is the only record: there is no database,
/// so files added, renamed or removed in Finder show up as they are.
public struct CaptureLibrary: Sendable {
    public let directory: URL
    private let remove: @Sendable (URL) throws -> Void

    public static var defaultDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("QuickShot", isDirectory: true)
    }

    /// - Parameter remove: how an item leaves the folder. The default moves it
    ///   to the Trash, where Finder can put it back.
    public init(
        directory: URL = CaptureLibrary.defaultDirectory,
        remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.directory = directory
        self.remove = remove
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Captures in the folder, newest first. Files of other types are ignored.
    public func items() throws -> [CaptureItem] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url -> CaptureItem? in
            guard let kind = Self.kind(forExtension: url.pathExtension),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { return nil }
            let created = values.creationDate ?? values.contentModificationDate ?? .distantPast
            return CaptureItem(url: url, kind: kind, created: created, byteCount: values.fileSize ?? 0)
        }
        .sorted { ($0.created, $0.url.lastPathComponent) > ($1.created, $1.url.lastPathComponent) }
    }

    public func trash(_ item: CaptureItem) throws {
        try remove(item.url)
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func kind(forExtension pathExtension: String) -> CaptureKind? {
        let lowered = pathExtension.lowercased()
        if imageExtensions.contains(lowered) { return .image }
        if videoExtensions.contains(lowered) { return .video }
        return nil
    }
}

/// Calls back when the contents of a folder change.
public final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    /// Returns `nil` when the folder cannot be opened.
    public init?(directory: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
