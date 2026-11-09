import Foundation

/// Saves a copy of an item into a folder. The item itself stays where it is.
public enum ClipExporter {
    /// Returns the files written.
    public static func export(_ item: ClipItem, from store: ClipStore, to folder: URL, date: Date = Date()) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch item.kind {
        case .text:
            let destination = unique("Clipboard Text \(stamp(date))", "txt", in: folder)
            try item.text.write(to: destination, atomically: true, encoding: .utf8)
            return [destination]
        case .image:
            guard let source = store.imageURL(for: item) else { return [] }
            let destination = unique("Clipboard Image \(stamp(date))", "png", in: folder)
            try FileManager.default.copyItem(at: source, to: destination)
            return [destination]
        case .files:
            return try item.filePaths.map { try copy(URL(fileURLWithPath: $0), to: folder) }
        }
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
