import Foundation

/// A scratch folder that is removed when the value is released.
public final class TempFolder {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    public func write(_ bytes: [UInt8], named name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(bytes).write(to: file)
        return file
    }

    /// Writes an executable shell script that stands in for the capture tool.
    /// The script receives the same arguments the real tool would; the output
    /// path is always the last one.
    public func script(_ body: String, named name: String = "fake-capture") throws -> URL {
        let file = url.appendingPathComponent(name)
        let text = "#!/bin/sh\nfor last; do :; done\nOUT=\"$last\"\n\(body)\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}

public enum Fixture {
    public static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]
    public static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1]
    public static let mov: [UInt8] = [0, 0, 0, 0x14] + Array("ftypqt  ".utf8) + [0, 0, 0, 0]
    public static let mp4: [UInt8] = [0, 0, 0, 0x18] + Array("ftypmp42".utf8) + [0, 0, 0, 0]
    public static let heic: [UInt8] = [0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0]
    public static let legacyMov: [UInt8] = [0, 0, 0, 0x08] + Array("wide".utf8) + [0, 0, 0, 0]
    public static let text: [UInt8] = Array("hello, world".utf8)

    /// `printf` escape for the PNG signature, for use inside a shell script.
    public static let pngPrintf = #"printf '\211PNG\r\n\032\n0000IHDR'"#
}
