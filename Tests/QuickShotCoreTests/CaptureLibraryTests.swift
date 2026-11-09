import Foundation
import Testing
@testable import QuickShotCore

@Suite struct CaptureLibraryTests {
    private func library(_ folder: TempFolder) -> CaptureLibrary {
        // Tests delete instead of using the Trash so they leave nothing behind.
        CaptureLibrary(directory: folder.url, remove: { try FileManager.default.removeItem(at: $0) })
    }

    private func setCreated(_ url: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -secondsAgo)],
            ofItemAtPath: url.path
        )
    }

    @Test func listsCapturesNewestFirst() throws {
        let folder = try TempFolder()
        let old = try folder.write(Fixture.png, named: "old.png")
        let new = try folder.write(Fixture.mov, named: "new.mov")
        let middle = try folder.write(Fixture.jpeg, named: "middle.JPG")
        try setCreated(old, secondsAgo: 300)
        try setCreated(middle, secondsAgo: 200)
        try setCreated(new, secondsAgo: 100)

        let items = try library(folder).items()

        #expect(items.map(\.url.lastPathComponent) == ["new.mov", "middle.JPG", "old.png"])
        #expect(items.map(\.kind) == [.video, .image, .image])
        #expect(items[2].byteCount == Fixture.png.count)
        #expect(items[0].name == "new")
    }

    @Test func ignoresFilesThatAreNotCaptures() throws {
        let folder = try TempFolder()
        _ = try folder.write(Fixture.png, named: "shot.png")
        _ = try folder.write(Fixture.text, named: "notes.txt")
        _ = try folder.write(Fixture.png, named: ".hidden.png")
        try FileManager.default.createDirectory(
            at: folder.url.appendingPathComponent("folder.png"), withIntermediateDirectories: true)

        #expect(try library(folder).items().map(\.url.lastPathComponent) == ["shot.png"])
    }

    @Test func anEmptyFolderListsNothing() throws {
        let folder = try TempFolder()
        #expect(try library(folder).items().isEmpty)
    }

    @Test func aMissingFolderIsCreatedOnDemand() throws {
        let parent = try TempFolder()
        let target = CaptureLibrary(directory: parent.url.appendingPathComponent("QuickShot"))

        #expect(throws: (any Error).self) { try target.items() }
        try target.ensureDirectory()
        #expect(try target.items().isEmpty)
    }

    @Test func trashingRemovesTheItemFromTheList() throws {
        let folder = try TempFolder()
        _ = try folder.write(Fixture.png, named: "keep.png")
        _ = try folder.write(Fixture.png, named: "drop.png")
        let target = library(folder)
        let drop = try #require(try target.items().first { $0.name == "drop" })

        try target.trash(drop)

        #expect(try target.items().map(\.name) == ["keep"])
    }

    @Test func theDefaultFolderIsQuickShotInsidePictures() {
        let path = CaptureLibrary.defaultDirectory.path
        #expect(path.hasSuffix("/Pictures/QuickShot"))
    }

    @Test func theWatcherReportsANewFile() async throws {
        let folder = try TempFolder()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let watcher = DirectoryWatcher(directory: folder.url, queue: .global()) { continuation.yield() }
        #expect(watcher != nil)

        _ = try folder.write(Fixture.png, named: "arrived.png")

        let noticed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(noticed, "no change event within 5 seconds")
        withExtendedLifetime(watcher) {}
    }

    @Test func theWatcherRefusesAFolderThatDoesNotExist() {
        #expect(DirectoryWatcher(directory: URL(fileURLWithPath: "/nonexistent-quickshot")) {} == nil)
    }
}
