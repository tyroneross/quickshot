import Foundation
import Testing
import TestSupport
@testable import QuickShotCore

@Suite struct CaptureFormatTests {
    @Test(arguments: [
        (Fixture.png, CaptureKind.image, "png"),
        (Fixture.jpeg, CaptureKind.image, "jpg"),
        (Fixture.heic, CaptureKind.image, "heic"),
        (Fixture.mov, CaptureKind.video, "mov"),
        (Fixture.legacyMov, CaptureKind.video, "mov"),
        (Fixture.mp4, CaptureKind.video, "mp4"),
    ])
    func recognisesTheFormatFromTheFirstBytes(bytes: [UInt8], kind: CaptureKind, ext: String) {
        #expect(CaptureFormat.detect(header: bytes) == CaptureFormat(kind: kind, fileExtension: ext))
    }

    /// A filed capture must always be listed: the library and the filer read
    /// the same table.
    @Test func everyFormatTheFilerProducesIsListedByTheLibrary() throws {
        let folder = try TempFolder()
        for format in CaptureFormat.all {
            #expect(CaptureFormat.kind(forExtension: format.fileExtension) == format.kind)
            try folder.write(Fixture.png, named: "sample.\(format.fileExtension)")
        }
        let listed = try CaptureLibrary(directory: folder.url).items()
        #expect(listed.count == CaptureFormat.all.count)
    }

    @Test func otherSpellingsAndUnknownExtensionsAreClassified() {
        #expect(CaptureFormat.kind(forExtension: "JPEG") == .image)
        #expect(CaptureFormat.kind(forExtension: "tif") == .image)
        #expect(CaptureFormat.kind(forExtension: "M4V") == .video)
        #expect(CaptureFormat.kind(forExtension: "txt") == nil)
        #expect(CaptureFormat.kind(forExtension: "") == nil)
    }

    @Test func rejectsContentThatIsNotACapture() {
        #expect(CaptureFormat.detect(header: Fixture.text) == nil)
        #expect(CaptureFormat.detect(header: []) == nil)
    }
}

@Suite struct CaptureFilerTests {
    let date = Date(timeIntervalSince1970: 1_794_206_467) // 2026-11-09 06:41:07 UTC
    let utc = TimeZone(identifier: "UTC")!

    @Test func filesAScreenshotUnderAKindAndTimeName() throws {
        let scratch = try TempFolder(), library = try TempFolder()
        let source = try scratch.write(Fixture.png, named: "capture.png")

        let filed = try CaptureFiler.file(source, into: library.url, date: date, timeZone: utc)

        #expect(filed.lastPathComponent == "Screenshot 2026-11-09 at 06.41.07.png")
        #expect(FileManager.default.fileExists(atPath: filed.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    /// The person can switch the toolbar to recording after a screenshot was
    /// requested, so a movie can arrive under a `.png` name.
    @Test func typesTheResultByContentNotByRequestedExtension() throws {
        let scratch = try TempFolder(), library = try TempFolder()
        let movieNamedPng = try scratch.write(Fixture.mov, named: "capture.png")
        let imageNamedMov = try scratch.write(Fixture.png, named: "capture.mov")

        let movie = try CaptureFiler.file(movieNamedPng, into: library.url, date: date, timeZone: utc)
        let image = try CaptureFiler.file(imageNamedMov, into: library.url, date: date, timeZone: utc)

        #expect(movie.lastPathComponent == "Recording 2026-11-09 at 06.41.07.mov")
        #expect(image.lastPathComponent == "Screenshot 2026-11-09 at 06.41.07.png")
    }

    @Test func twoCapturesInTheSameSecondKeepBothFiles() throws {
        let scratch = try TempFolder(), library = try TempFolder()
        let first = try scratch.write(Fixture.png, named: "a.png")
        let second = try scratch.write(Fixture.png, named: "b.png")

        let one = try CaptureFiler.file(first, into: library.url, date: date, timeZone: utc)
        let two = try CaptureFiler.file(second, into: library.url, date: date, timeZone: utc)

        #expect(one.lastPathComponent == "Screenshot 2026-11-09 at 06.41.07.png")
        #expect(two.lastPathComponent == "Screenshot 2026-11-09 at 06.41.07 (2).png")
    }

    @Test func refusesAFileItCannotRecogniseAndLeavesItInPlace() throws {
        let scratch = try TempFolder(), library = try TempFolder()
        let source = try scratch.write(Fixture.text, named: "capture.png")

        #expect(throws: CaptureFilerError.unrecognised("capture.png")) {
            try CaptureFiler.file(source, into: library.url, date: date, timeZone: utc)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.url.path).isEmpty)
    }

    private func scratchFolder(in parent: TempFolder) throws -> URL {
        let scratch = parent.url.appendingPathComponent("QuickShot-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    /// A capture in a format the filer cannot type is the person's only copy.
    @Test func fileAllKeepsACaptureItCannotRecogniseAndSaysWhereItIs() throws {
        let parent = try TempFolder(), library = try TempFolder()
        let scratch = try scratchFolder(in: parent)
        let good = scratch.appendingPathComponent("capture.png")
        let bad = scratch.appendingPathComponent("capture-2.bmp")
        try Data(Fixture.png).write(to: good)
        try Data(Fixture.text).write(to: bad)

        let outcome = CaptureFiler.fileAll([good, bad], into: library.url, date: date, timeZone: utc)

        #expect(outcome.filed.map(\.lastPathComponent) == ["Screenshot 2026-11-09 at 06.41.07.png"])
        let kept = library.url.appendingPathComponent("Unfiled capture 2026-11-09 at 06.41.07.bmp")
        #expect(try Data(contentsOf: kept) == Data(Fixture.text), "the unrecognised capture must survive intact")
        #expect(outcome.problems.count == 1)
        #expect(outcome.problems.first?.contains(kept.path) == true, "the notice must say where the file is")
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "an emptied scratch folder is removed")
    }

    /// When the captures folder itself is unusable, the capture stays where
    /// the tool wrote it and the scratch folder is not removed.
    @Test func fileAllLeavesTheCaptureInScratchWhenTheFolderIsUnusable() throws {
        let parent = try TempFolder()
        let scratch = try scratchFolder(in: parent)
        let capture = scratch.appendingPathComponent("capture.png")
        try Data(Fixture.png).write(to: capture)
        // A plain file where the captures folder should be.
        let blocked = try parent.write(Fixture.text, named: "not-a-folder")

        let outcome = CaptureFiler.fileAll([capture], into: blocked, date: date, timeZone: utc)

        #expect(outcome.filed.isEmpty)
        #expect(try Data(contentsOf: capture) == Data(Fixture.png), "the capture must not be deleted")
        #expect(outcome.problems.first?.contains(capture.path) == true)
    }

    @Test func fileAllRemovesTheScratchFolderOnceEverythingIsFiled() throws {
        let parent = try TempFolder(), library = try TempFolder()
        let scratch = try scratchFolder(in: parent)
        let capture = scratch.appendingPathComponent("capture.mov")
        try Data(Fixture.mov).write(to: capture)

        let outcome = CaptureFiler.fileAll([capture], into: library.url, date: date, timeZone: utc)

        #expect(outcome.problems.isEmpty)
        #expect(outcome.filed.map(\.lastPathComponent) == ["Recording 2026-11-09 at 06.41.07.mov"])
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func createsTheCapturesFolderWhenItIsMissing() throws {
        let scratch = try TempFolder(), parent = try TempFolder()
        let source = try scratch.write(Fixture.png, named: "capture.png")
        let missing = parent.url.appendingPathComponent("QuickShot", isDirectory: true)

        let filed = try CaptureFiler.file(source, into: missing, date: date, timeZone: utc)

        #expect(filed.deletingLastPathComponent().lastPathComponent == "QuickShot")
    }
}
