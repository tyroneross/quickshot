import Foundation

public enum CaptureKind: String, Sendable, CaseIterable {
    case image
    case video
}

/// A file type recognised from the first bytes of a file.
public struct CaptureFormat: Sendable, Equatable {
    public let kind: CaptureKind
    public let fileExtension: String

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
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .init(kind: .image, fileExtension: "png") }
        if starts([0xFF, 0xD8, 0xFF]) { return .init(kind: .image, fileExtension: "jpg") }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) {
            return .init(kind: .image, fileExtension: "tiff")
        }
        if starts(Array("%PDF".utf8)) { return .init(kind: .image, fileExtension: "pdf") }
        if starts(Array("GIF8".utf8)) { return .init(kind: .image, fileExtension: "gif") }

        guard header.count >= 8 else { return nil }
        let boxType = String(decoding: header[4..<8], as: UTF8.self)
        if boxType == "ftyp", header.count >= 12 {
            let brand = String(decoding: header[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1"].contains(brand) {
                return .init(kind: .image, fileExtension: "heic")
            }
            return .init(kind: .video, fileExtension: brand == "qt  " ? "mov" : "mp4")
        }
        // QuickTime movies may open with one of these atoms instead of `ftyp`.
        if ["moov", "mdat", "wide", "free", "skip"].contains(boxType) {
            return .init(kind: .video, fileExtension: "mov")
        }
        return nil
    }
}

public enum CaptureFilerError: Error, Equatable, LocalizedError {
    case unrecognised(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognised(let name): "The capture tool wrote a file QuickShot does not recognise (\(name))."
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

    /// Files everything one capture produced and clears its scratch folder.
    /// A file that cannot be filed is reported and does not stop the others.
    public static func fileAll(
        _ sources: [URL],
        into directory: URL,
        date: Date = Date()
    ) -> (filed: [URL], problems: [String]) {
        var filed: [URL] = []
        var problems: [String] = []
        for source in sources {
            do {
                filed.append(try file(source, into: directory, date: date))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        for scratch in Set(sources.map { $0.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: scratch)
        }
        return (filed, problems)
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
