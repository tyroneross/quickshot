import AppKit
import Foundation
import Testing
import TestSupport
@testable import ClipboardCore

/// A real PNG of the given size.
func makePNG(width: Int = 40, height: Int = 30, white: CGFloat = 0.5) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: white, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func imageCandidate(width: Int = 40, height: Int = 30, white: CGFloat = 0.5) -> ClipCandidate {
    ClipCandidate(kind: .image, imageData: makePNG(width: width, height: height, white: white),
                  pixelWidth: width, pixelHeight: height)
}

@Suite struct ClipStoreTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordsTextAndListsNewestFirst() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)

        try store.record(.text("first", sourceApp: "com.example.editor"), at: now)
        try store.record(.text("second\nline two"), at: now.addingTimeInterval(5))

        let items = try store.items(in: .history)
        #expect(items.map(\.text) == ["second\nline two", "first"])
        #expect(items[0].title == "second")
        #expect(items[1].sourceApp == "com.example.editor")
        #expect(items[1].kind == .text)
        #expect(items[1].byteCount == 5)
    }

    @Test func theSameContentCopiedAgainUpdatesTheItemInsteadOfAddingOne() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let first = try #require(try store.record(.text("alpha"), at: now))
        try store.record(.text("beta"), at: now.addingTimeInterval(1))

        let again = try #require(try store.record(.text("alpha"), at: now.addingTimeInterval(60)))

        #expect(again.id == first.id)
        #expect(again.created == first.created)
        #expect(again.lastCopied == now.addingTimeInterval(60))
        #expect(try store.items(in: .history).map(\.text) == ["alpha", "beta"], "the re-copied item moves to the top")
    }

    @Test func imagesAreStoredAsFilesNamedByHash() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let candidate = imageCandidate(width: 64, height: 48)

        let item = try #require(try store.record(candidate, at: now))

        let url = try #require(store.imageURL(for: item))
        #expect(try Data(contentsOf: url) == candidate.imageData)
        #expect(url.lastPathComponent == "\(ClipStore.hash(candidate)).png")
        #expect(item.title == "Image 64 × 48")
        #expect(item.text.isEmpty)
        // The same picture again does not write a second file.
        try store.record(candidate, at: now.addingTimeInterval(9))
        let images = try FileManager.default.contentsOfDirectory(atPath: folder.url.appendingPathComponent("images").path)
        #expect(images.count == 1)
    }

    @Test func filesAreKeptAsPathsAndNamedInTheTitle() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)

        let one = try #require(try store.record(.files([URL(fileURLWithPath: "/tmp/report.pdf")]), at: now))
        let three = try #require(try store.record(.files([
            URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png"), URL(fileURLWithPath: "/tmp/c.png"),
        ]), at: now))

        #expect(one.title == "report.pdf")
        #expect(three.title == "a.png and 2 more")
        #expect(three.filePaths == ["/tmp/a.png", "/tmp/b.png", "/tmp/c.png"])
    }

    @Test func emptyAndOversizedCopiesAreNotRecorded() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)

        #expect(try store.record(.text("")) == nil)
        let tooBig = ClipCandidate(kind: .image, imageData: Data(count: ClipStore.maxItemBytes + 1), pixelWidth: 1, pixelHeight: 1)
        #expect(try store.record(tooBig) == nil)
        let atLimit = ClipCandidate(kind: .image, imageData: Data(count: ClipStore.maxItemBytes), pixelWidth: 1, pixelHeight: 1)
        #expect(try store.record(atLimit) != nil)
        #expect(try store.items(in: .history).count == 1)
    }

    @Test func searchMatchesASubstringIgnoringCaseAndTreatsWildcardsAsText() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        try store.record(.text("Invoice 2026 for Acme"), at: now)
        try store.record(.text("100% done"), at: now.addingTimeInterval(1))
        try store.record(.text("snake_case_name"), at: now.addingTimeInterval(2))
        try store.record(.text("snakeXcase"), at: now.addingTimeInterval(3))

        #expect(try store.items(in: .history, matching: "acme").map(\.text) == ["Invoice 2026 for Acme"])
        #expect(try store.items(in: .history, matching: "%").map(\.text) == ["100% done"])
        #expect(try store.items(in: .history, matching: "snake_case").map(\.text) == ["snake_case_name"])
        #expect(try store.items(in: .history, matching: "nothing like this").isEmpty)
        #expect(try store.items(in: .history, matching: "   ").count == 4)
    }

    @Test func collectionsHoldItemsAndSurviveDeletingTheCollection() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let keep = try #require(try store.record(.text("keep me"), at: now))
        let other = try #require(try store.record(.text("other"), at: now.addingTimeInterval(1)))
        let work = try store.createCollection(named: "  Work  ")
        let later = try store.createCollection(named: "later")

        try store.add(keep, to: work)
        try store.add(keep, to: work) // adding twice is harmless
        try store.add(keep, to: later)
        try store.add(other, to: later)

        #expect(work.name == "Work")
        #expect(try store.collections().map(\.name) == ["later", "Work"])
        #expect(try store.items(in: .collection(work.id)).map(\.text) == ["keep me"])
        #expect(try store.items(in: .collection(later.id), matching: "oth").map(\.text) == ["other"])
        #expect(try store.collectionIDs(containing: keep) == [work.id, later.id])

        try store.remove(keep, from: later)
        #expect(try store.collectionIDs(containing: keep) == [work.id])

        try store.renameCollection(work, to: "Projects")
        try store.deleteCollection(later)
        #expect(try store.collections().map(\.name) == ["Projects"])
        #expect(try store.items(in: .history).count == 2, "deleting a collection keeps its items")
    }

    @Test func aCollectionNeedsAName() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        #expect(throws: ClipStoreError.emptyName) { try store.createCollection(named: "   ") }
        let real = try store.createCollection(named: "Real")
        #expect(throws: ClipStoreError.emptyName) { try store.renameCollection(real, to: "") }
        #expect(try store.collections().map(\.name) == ["Real"])
    }

    @Test func oldHistoryExpiresButSavedItemsDoNot() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let oldLoose = try #require(try store.record(imageCandidate(white: 0.2), at: now.addingTimeInterval(-91 * day)))
        let oldSaved = try #require(try store.record(.text("old but saved"), at: now.addingTimeInterval(-200 * day)))
        try store.record(.text("recent"), at: now.addingTimeInterval(-89 * day))
        try store.add(oldSaved, to: try store.createCollection(named: "Keep"))
        let image = try #require(store.imageURL(for: oldLoose))

        let removed = try store.expire(now: now)

        #expect(removed == 1)
        #expect(try store.items(in: .history).map(\.text) == ["recent", "old but saved"])
        #expect(!FileManager.default.fileExists(atPath: image.path), "an expired image's file is removed with it")
    }

    @Test func deletingAnItemRemovesItFromCollectionsAndDeletesItsImage() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let item = try #require(try store.record(imageCandidate(), at: now))
        let collection = try store.createCollection(named: "Pics")
        try store.add(item, to: collection)
        let image = try #require(store.imageURL(for: item))

        try store.delete(item)

        #expect(try store.items(in: .history).isEmpty)
        #expect(try store.items(in: .collection(collection.id)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test func historyIsStillThereAfterReopeningTheStore() throws {
        let folder = try TempFolder()
        do {
            let store = try ClipStore(directory: folder.url)
            try store.record(.text("persisted"), at: now)
            try store.createCollection(named: "Saved")
        }
        let reopened = try ClipStore(directory: folder.url)
        #expect(try reopened.items(in: .history).map(\.text) == ["persisted"])
        #expect(try reopened.collections().map(\.name) == ["Saved"])
    }
}
