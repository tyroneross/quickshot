import Foundation

public enum ClipExportError: Error, Equatable, LocalizedError {
    case missingFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let name): "\(name) was moved or deleted, so nothing was saved."
        }
    }
}

/// Saves a copy of an item into a folder. The item itself stays where it is.
public enum ClipExporter {
    /// Returns the files written.
    public static func export(_ item: ClipItem, from store: ClipStore, to folder: URL, date: Date = Date()) throws -> [URL] {
        switch item.kind {
        case .text:
            return [try exportText(item.text, to: folder, date: date)]
        case .image:
            guard let source = store.imageURL(for: item) else { return [] }
            return [try exportImage(at: source, to: folder, date: date)]
        case .files:
            return try exportFiles(item.filePaths, to: folder)
        }
    }

    // The three pieces below need no store, so a caller can run them off the
    // main thread with plain values.

    public static func exportText(_ text: String, to folder: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = unique("Clipboard Text \(stamp(date))", "txt", in: folder)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    public static func exportImage(at source: URL, to folder: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = unique("Clipboard Image \(stamp(date))", "png", in: folder)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    public static func exportFiles(_ paths: [String], to folder: URL) throws -> [URL] {
        // Check every file first, so a missing one cannot leave a partial export.
        if let missing = paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            throw ClipExportError.missingFile((missing as NSString).lastPathComponent)
        }
        return try paths.map { try copy(URL(fileURLWithPath: $0), to: folder) }
    }

    /// Copies one file into a folder under its own name, never over another file.
    public static func copy(_ source: URL, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = unique(source.deletingPathExtension().lastPathComponent, source.pathExtension, in: folder)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func unique(_ base: String, _ ext: String, in folder: URL) -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = folder.appendingPathComponent(base + suffix)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter))\(suffix)")
            counter += 1
        }
        return candidate
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
