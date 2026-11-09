import Foundation
import Testing
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

    @Test func fileAllFilesWhatItCanReportsTheRestAndClearsScratch() throws {
        let parent = try TempFolder(), library = try TempFolder()
        let scratch = parent.url.appendingPathComponent("QuickShot-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let good = scratch.appendingPathComponent("capture.png")
        let bad = scratch.appendingPathComponent("capture-2.png")
        try Data(Fixture.png).write(to: good)
        try Data(Fixture.text).write(to: bad)

        let outcome = CaptureFiler.fileAll([good, bad], into: library.url, date: date)

        #expect(outcome.filed.count == 1)
        #expect(outcome.filed.first?.pathExtension == "png")
        #expect(outcome.problems.count == 1)
        #expect(outcome.problems.first?.contains("capture-2.png") == true)
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
