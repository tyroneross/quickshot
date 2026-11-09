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

    /// SQLite's C interface stops at a zero byte unless told the length.
    @Test func textWithANULCharacterIsStoredWhole() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let text = "before\u{0}after-the-nul"

        let item = try #require(try store.record(.text(text), at: now))

        #expect(item.text == text)
        #expect(try store.items(in: .history).first?.text.utf8.count == text.utf8.count)
        // The plain prefix is different content and gets its own item.
        try store.record(.text("before"), at: now.addingTimeInterval(1))
        #expect(try store.items(in: .history).count == 2)
    }

    /// A file name may contain a line break; the list must not split on it.
    @Test func aFileNameContainingALineBreakStaysOneFile() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        let odd = URL(fileURLWithPath: "/tmp/first line\nsecond line.txt")

        let item = try #require(try store.record(.files([odd, URL(fileURLWithPath: "/tmp/plain.txt")]), at: now))

        #expect(item.filePaths == [odd.path, "/tmp/plain.txt"])
        #expect(try store.items(in: .history, matching: "plain").count == 1)
        #expect(try store.items(in: .history, matching: "tmp/plain").count == 1, "a path fragment with a slash must match")
    }

    /// Putting a capture into a collection is not a copy: it must not show up
    /// in History or move anything.
    @Test func aReferenceIsNotACopyAndIsRemovedWhenNothingHoldsIt() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        try store.record(.text("real copy"), at: now)
        let collection = try store.createCollection(named: "Bugs")
        let capture = ClipCandidate.files([URL(fileURLWithPath: "/tmp/Screenshot.png")])

        let reference = try #require(try store.reference(capture, at: now.addingTimeInterval(50)))
        try store.add(reference, to: collection)
        #expect(try store.reference(capture)?.id == reference.id, "asking again returns the same item, untouched")

        #expect(try store.items(in: .history).map(\.kind) == [.text], "a reference must not appear in History")
        #expect(try store.items(in: .collection(collection.id)).map(\.id) == [reference.id])

        // A real copy of the same file later does belong in History.
        try store.record(capture, at: now.addingTimeInterval(99))
        #expect(try store.items(in: .history).count == 2)
        try store.remove(reference, from: collection)
        #expect(try store.items(in: .history).count == 2, "an item that was really copied survives leaving the collection")

        let other = try #require(try store.reference(.files([URL(fileURLWithPath: "/tmp/Other.png")])))
        try store.add(other, to: collection)
        try store.remove(other, from: collection)
        #expect(try store.item(id: other.id) == nil, "a reference nothing holds is removed")
    }

    /// An earlier build stored file lists one path per line.
    @Test func aFileListInTheOlderFormStillReadsAsPaths() {
        #expect(FilePaths.decode("/tmp/a.png\n/tmp/b.png") == ["/tmp/a.png", "/tmp/b.png"])
        #expect(FilePaths.decode(FilePaths.encode(["/tmp/with \"quotes\".txt"])) == ["/tmp/with \"quotes\".txt"])
        #expect(FilePaths.encode(["/tmp/a.png"]).contains("/tmp/a.png"), "slashes stay unescaped so paths remain searchable")
    }

    /// A store written before the `in_history` column existed must open,
    /// list its history and accept new copies.
    @Test func aStoreFromBeforeTheHistoryColumnIsUpgradedOnOpen() throws {
        let folder = try TempFolder()
        do {
            let old = try SQLiteDatabase(path: folder.url.appendingPathComponent("clipboard.sqlite").path)
            try old.execute("""
                CREATE TABLE items (
                    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, image_file TEXT,
                    width INTEGER NOT NULL, height INTEGER NOT NULL, bytes INTEGER NOT NULL, source_app TEXT,
                    created REAL NOT NULL, last_copied REAL NOT NULL, hash TEXT NOT NULL UNIQUE)
                """)
            try old.execute("INSERT INTO items (kind, text, width, height, bytes, created, last_copied, hash) VALUES ('text', 'from the old store', 0, 0, 18, 1, 1, 'legacy-hash')")
        }

        let store = try ClipStore(directory: folder.url)

        #expect(try store.items(in: .history).map(\.text) == ["from the old store"])
        try store.record(.text("new copy"), at: now)
        #expect(try store.items(in: .history).map(\.text) == ["new copy", "from the old store"])
    }

    @Test func aListIsBoundedButSearchLooksThroughEverything() throws {
        let folder = try TempFolder()
        let store = try ClipStore(directory: folder.url)
        try store.record(.text("the needle in the oldest item"), at: now)
        for index in 1...ClipStore.listLimit {
            try store.record(.text("filler \(index)"), at: now.addingTimeInterval(Double(index)))
        }

        #expect(try store.items(in: .history).count == ClipStore.listLimit)
        #expect(try store.items(in: .history).last?.text == "filler 1", "the oldest item falls outside the list")
        #expect(try store.items(in: .history, matching: "needle").map(\.text) == ["the needle in the oldest item"])
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

        try store.record(.text("Menu de l'école"), at: now.addingTimeInterval(4))
        #expect(try store.items(in: .history, matching: "ÉCOLE").map(\.text) == ["Menu de l'école"], "case folding must cover non-ASCII letters")
        #expect(try store.items(in: .history, matching: "ecole").map(\.text) == ["Menu de l'école"], "accents are ignored, as in Finder search")
        #expect(try store.items(in: .history, matching: "acme").map(\.text) == ["Invoice 2026 for Acme"])
        #expect(try store.items(in: .history, matching: "%").map(\.text) == ["100% done"])
        #expect(try store.items(in: .history, matching: "snake_case").map(\.text) == ["snake_case_name"])
        #expect(try store.items(in: .history, matching: "nothing like this").isEmpty)
        #expect(try store.items(in: .history, matching: "   ").count == 5)
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
