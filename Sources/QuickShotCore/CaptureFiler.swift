import Foundation

public enum CaptureKind: String, Sendable, CaseIterable {
    case image
    case video
}

/// A file type recognised from the first bytes of a file.
public struct CaptureFormat: Sendable, Equatable {
    public let kind: CaptureKind
    public let fileExtension: String

    static let png = CaptureFormat(kind: .image, fileExtension: "png")
    static let jpeg = CaptureFormat(kind: .image, fileExtension: "jpg")
    static let tiff = CaptureFormat(kind: .image, fileExtension: "tiff")
    static let pdf = CaptureFormat(kind: .image, fileExtension: "pdf")
    static let gif = CaptureFormat(kind: .image, fileExtension: "gif")
    static let heic = CaptureFormat(kind: .image, fileExtension: "heic")
    static let quickTime = CaptureFormat(kind: .video, fileExtension: "mov")
    static let mpeg4 = CaptureFormat(kind: .video, fileExtension: "mp4")

    /// Every format the filer can produce. The library lists exactly these,
    /// so a filed capture can never be invisible in the grid.
    static let all: [CaptureFormat] = [png, jpeg, tiff, pdf, gif, heic, quickTime, mpeg4]

    /// Other spellings people use for the same formats on files they add.
    private static let aliases: [String: CaptureKind] = ["jpeg": .image, "tif": .image, "m4v": .video]

    /// The kind of capture a file extension denotes, or `nil` for other files.
    public static func kind(forExtension pathExtension: String) -> CaptureKind? {
        let lowered = pathExtension.lowercased()
        return all.first { $0.fileExtension == lowered }?.kind ?? aliases[lowered]
    }

    /// Reads the file signature. The toolbar lets the person switch between a
    /// still and a recording after launch, so the requested name cannot be
    /// trusted to say what was written.
    public static func detect(_ url: URL) -> CaptureFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12) else { return nil }
        return detect(header: [UInt8](data))
    }

    static func detect(header: [UInt8]) -> CaptureFormat? {
        func starts(_ signature: [UInt8]) -> Bool {
            header.count >= signature.count && Array(header.prefix(signature.count)) == signature
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts(Array("GIF8".utf8)) { return .gif }

        guard header.count >= 8 else { return nil }
        let boxType = String(decoding: header[4..<8], as: UTF8.self)
        if boxType == "ftyp", header.count >= 12 {
            let brand = String(decoding: header[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1"].contains(brand) { return .heic }
            return brand == "qt  " ? .quickTime : .mpeg4
        }
        // QuickTime movies may open with one of these atoms instead of `ftyp`.
        if ["moov", "mdat", "wide", "free", "skip"].contains(boxType) { return .quickTime }
        return nil
    }
}

public enum CaptureFilerError: Error, Equatable, LocalizedError {
    case unrecognised(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognised(let name): "The capture tool wrote a file in a format QuickShot does not recognise (\(name))."
        }
    }
}

/// Moves a finished capture out of scratch space into the captures folder.
public enum CaptureFiler {
    /// Returns the new location. The name carries the kind and local time,
    /// e.g. `Screenshot 2026-11-08 at 22.41.07.png`.
    public static func file(
        _ source: URL,
        into directory: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> URL {
        guard let format = CaptureFormat.detect(source) else {
            throw CaptureFilerError.unrecognised(source.lastPathComponent)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = "\(prefix(for: format.kind)) \(stamp(date, timeZone: timeZone))"
        var destination = directory.appendingPathComponent("\(base).\(format.fileExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    /// Files everything one capture produced. No capture is ever deleted: a
    /// file whose format is not recognised is kept in the captures folder
    /// under an "Unfiled capture" name, and if even that fails it stays where
    /// the tool wrote it. Each case is reported with the file's location.
    public static func fileAll(
        _ sources: [URL],
        into directory: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> (filed: [URL], problems: [String]) {
        var filed: [URL] = []
        var problems: [String] = []
        for source in sources {
            do {
                filed.append(try file(source, into: directory, date: date, timeZone: timeZone))
            } catch {
                problems.append(keep(source, in: directory, date: date, timeZone: timeZone, because: error))
            }
        }
        // `rmdir` removes only an empty folder, so it cannot take a capture with it.
        for scratch in Set(sources.map { $0.deletingLastPathComponent() }) {
            rmdir(scratch.path)
        }
        return (filed, problems)
    }

    /// Moves a capture that could not be filed normally into the captures
    /// folder as it is, and says where it ended up.
    private static func keep(
        _ source: URL, in directory: URL, date: Date, timeZone: TimeZone, because error: Error
    ) -> String {
        let fileManager = FileManager.default
        let base = "Unfiled capture \(stamp(date, timeZone: timeZone))"
        let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
        var destination = directory.appendingPathComponent(base + ext)
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) (\(counter))\(ext)")
            counter += 1
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            return "\(error.localizedDescription) It was kept as \(destination.path)."
        } catch {
            return "A capture could not be moved into the captures folder (\(error.localizedDescription)). It is still at \(source.path)."
        }
    }

    static func prefix(for kind: CaptureKind) -> String {
        switch kind {
        case .image: "Screenshot"
        case .video: "Recording"
        }
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
