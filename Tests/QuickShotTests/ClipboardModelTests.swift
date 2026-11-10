import AppKit
import ClipboardCore
import Foundation
import QuickShotCore
import TestSupport
import Testing
@testable import QuickShot

/// A clipboard model on a scratch store and a private pasteboard, so no test
/// reads or changes the real clipboard.
@MainActor
final class ClipboardHarness {
    let folder: TempFolder
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("quickshot-library-test-\(UUID().uuidString)"))
    let store: ClipStore
    let model: ClipboardModel
    var captures: [CaptureItem] = []
    var denied = false
    let defaults: UserDefaults
    private let defaultsName = "quickshot-test-\(UUID().uuidString)"

    init(paused: Bool = false) throws {
        defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(paused, forKey: ClipboardModel.pausedKey)
        folder = try TempFolder()
        store = try ClipStore(directory: folder.url.appendingPathComponent("store"))
        pasteboard.clearContents()
        var readCaptures: () -> [CaptureItem] = { [] }
        var isDenied: () -> Bool = { false }
        model = ClipboardModel(
            store: store, pasteboard: pasteboard,
            captures: { readCaptures() }, defaults: defaults,
            frontmostApp: { "com.example.editor" }, accessDenied: { isDenied() })
        readCaptures = { [unowned self] in captures }
        isDenied = { [unowned self] in denied }
    }

    isolated deinit {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: defaultsName)
    }

    /// Simulates another app copying text, then lets the monitor notice.
    func copyElsewhere(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        model.monitor.tick()
    }

    func addCapture(named name: String, kind: CaptureKind = .image) throws -> CaptureItem {
        let url = folder.url.appendingPathComponent(name)
        if kind == .image { try writeRealPNG(to: url, hue: 0.6) } else { try Data(Fixture.mov).write(to: url) }
        let item = CaptureItem(url: url, kind: kind, created: Date(), byteCount: 100)
        captures.append(item)
        return item
    }

    var titles: [String] { model.entries.map(\.title) }
}

@MainActor
@Suite struct ClipboardModelTests {
    @Test func aNewCopyAppearsAndTheSelectionStaysOnTheSameItem() throws {
        let harness = try ClipboardHarness()
        harness.model.start()
        harness.model.monitor.stop()
        harness.copyElsewhere("first")
        let first = try #require(harness.model.entries.first)
        harness.model.selection = first.id

        harness.copyElsewhere("second")

        #expect(harness.titles == ["second", "first"])
        #expect(harness.model.selectedEntry?.title == "first", "a new copy must not move the selection to another item")
    }

    @Test func copyingAnEntryBackDoesNotAddOrReorderHistory() throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("older")
        harness.copyElsewhere("newer")
        let older = try #require(harness.model.entries.last)

        harness.model.copy(older)
        harness.model.monitor.tick()

        #expect(harness.pasteboard.string(forType: .string) == "older")
        #expect(harness.titles == ["newer", "older"])
        #expect(harness.model.copiedEntry == older.id)
    }

    @Test func exportSavesACopyGivesAReceiptAndKeepsTheItem() async throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("export me")
        let entry = try #require(harness.model.entries.first)
        let destination = harness.folder.url.appendingPathComponent("Exports")

        await harness.model.export(entry, to: destination).value

        let written = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(written.count == 1)
        #expect(try String(contentsOf: destination.appendingPathComponent(written[0]), encoding: .utf8) == "export me")
        #expect(harness.model.receipt?.contains(written[0]) == true)
        #expect(harness.titles == ["export me"])
        #expect(harness.model.problem == nil)
    }

    @Test func exportingAnImageWritesThePNG() async throws {
        let harness = try ClipboardHarness()
        let picture = harness.folder.url.appendingPathComponent("p.png")
        try writeRealPNG(to: picture, width: 60, height: 40, hue: 0.4)
        let data = try Data(contentsOf: picture)
        try harness.store.record(ClipCandidate(kind: .image, imageData: data, pixelWidth: 60, pixelHeight: 40))
        harness.model.reload()
        let entry = try #require(harness.model.entries.first)
        let destination = harness.folder.url.appendingPathComponent("Exports")

        await harness.model.export(entry, to: destination).value

        let written = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(written.count == 1 && written[0].hasSuffix(".png"))
        #expect(try Data(contentsOf: destination.appendingPathComponent(written[0])) == data)
        #expect(harness.model.problem == nil)
    }

    /// Copying a few selected words must not add an item (or bring back one
    /// that was just deleted).
    @Test func copyingSelectedWordsIsNotRecordedAsANewItem() throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("a long private note")
        let entry = try #require(harness.model.entries.first)

        harness.model.copySelectedText("private note")
        harness.model.delete(entry)
        harness.model.monitor.tick()

        #expect(harness.pasteboard.string(forType: .string) == "private note")
        #expect(harness.titles.isEmpty, "the selected words were recorded as a new history item")
    }

    @Test func exportingACaptureCopiesTheFileAndLeavesTheOriginal() async throws {
        let harness = try ClipboardHarness()
        let capture = try harness.addCapture(named: "Screenshot A.png")
        let destination = harness.folder.url.appendingPathComponent("Exports")

        await harness.model.export(.capture(capture), to: destination).value

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Screenshot A.png").path))
        #expect(FileManager.default.fileExists(atPath: capture.url.path))
        #expect(harness.model.receipt?.contains("Screenshot A.png") == true)
    }

    /// The capture was renamed or trashed after it joined a collection.
    @Test func aCollectedCaptureThatWasDeletedIsReportedNotCopied() async throws {
        let harness = try ClipboardHarness()
        let capture = try harness.addCapture(named: "Screenshot gone.png")
        let collection = try #require(harness.model.createCollection(named: "Bugs"))
        harness.model.add(.capture(capture), to: collection)
        harness.model.section = .collection(collection.id)
        let held = try #require(harness.model.entries.first)
        try FileManager.default.removeItem(at: capture.url)

        harness.model.copy(held)
        #expect(harness.model.copiedEntry == nil, "a dead reference must not report Copied")
        #expect(harness.model.problem?.contains("moved or deleted") == true)

        harness.model.problem = nil
        await harness.model.export(held, to: harness.folder.url.appendingPathComponent("Exports")).value
        #expect(harness.model.problem == "Screenshot gone.png was moved or deleted, so nothing was saved.")
        #expect(harness.model.receipt == nil)
    }

    @Test func aCaptureJoinsACollectionAsAReferenceToItsFile() throws {
        let harness = try ClipboardHarness()
        let capture = try harness.addCapture(named: "Screenshot B.png")
        let collection = try #require(harness.model.createCollection(named: "Bugs"))
        let entry = LibraryEntry.capture(capture)
        #expect(harness.model.collectionIDs(for: entry).isEmpty)

        harness.model.add(entry, to: collection)

        #expect(harness.model.collectionIDs(for: entry) == [collection.id])
        harness.model.section = .collection(collection.id)
        let held = try #require(harness.model.clips.first)
        #expect(held.kind == .files)
        #expect(held.filePaths == [capture.url.path], "the capture is referenced in place, not copied")
        #expect(try harness.store.items(in: .history).isEmpty, "adding a capture to a collection is not a copy in History")

        harness.model.remove(entry, from: collection)
        #expect(harness.model.clips.isEmpty)
        #expect(try harness.store.find(.files([capture.url])) == nil, "the unused reference is removed")
    }

    @Test func deletingRemovesACopiedItemButNeverACapture() throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("delete me")
        let clip = try #require(harness.model.entries.first)
        harness.model.selection = clip.id
        let capture = try harness.addCapture(named: "Screenshot C.png")

        harness.model.delete(clip)
        harness.model.delete(.capture(capture))

        #expect(harness.titles.isEmpty)
        #expect(harness.model.selection == nil)
        #expect(FileManager.default.fileExists(atPath: capture.url.path), "captures are not deleted from the library")
    }

    /// Deleting something the person saved in a collection needs a confirmation;
    /// deleting plain history and anything about a capture does not.
    @Test func onlyDeletingASavedItemNeedsConfirmation() throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("loose")
        harness.copyElsewhere("saved")
        let saved = try #require(harness.model.entries.first { $0.title == "saved" })
        let loose = try #require(harness.model.entries.first { $0.title == "loose" })
        let collection = try #require(harness.model.createCollection(named: "Keep"))
        harness.model.add(saved, to: collection)
        let capture = try harness.addCapture(named: "Screenshot E.png")

        #expect(harness.model.deletionRemovesSavedItem(saved))
        #expect(!harness.model.deletionRemovesSavedItem(loose))
        #expect(!harness.model.deletionRemovesSavedItem(.capture(capture)))
    }

    @Test func switchingSectionClearsTheSelectionAndADeletedCollectionFallsBackToHistory() throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("something")
        harness.model.selection = harness.model.entries.first?.id
        let collection = try #require(harness.model.createCollection(named: "Temp"))

        harness.model.section = .collection(collection.id)
        #expect(harness.model.selection == nil)
        #expect(harness.titles.isEmpty)

        harness.model.delete(collection)
        #expect(harness.model.section == .history)
        #expect(harness.titles == ["something"])
    }

    @Test func screenshotsAreListedFromQuickShotAndFilteredBySearch() throws {
        let harness = try ClipboardHarness()
        _ = try harness.addCapture(named: "Screenshot login.png")
        _ = try harness.addCapture(named: "Recording demo.mov", kind: .video)

        harness.model.section = .captures
        #expect(Set(harness.titles) == ["Screenshot login", "Recording demo"])
        #expect(harness.model.entries.map(\.kindWord).sorted() == ["Recording", "Screenshot"])

        harness.model.searchText = "LOGIN"
        #expect(harness.titles == ["Screenshot login"])
    }

    @Test func searchFiltersHistory() throws {
        let harness = try ClipboardHarness()
        harness.copyElsewhere("alpha report")
        harness.copyElsewhere("beta notes")

        harness.model.searchText = "report"
        #expect(harness.titles == ["alpha report"])
        harness.model.searchText = ""
        #expect(harness.titles.count == 2)
    }

    @Test func aBlockedOrPausedClipboardIsReflectedInTheState() throws {
        let harness = try ClipboardHarness()
        harness.denied = true
        harness.copyElsewhere("blocked")
        #expect(harness.model.monitorState == .blocked)
        #expect(harness.titles.isEmpty)

        harness.denied = false
        harness.model.monitor.tick()
        #expect(harness.model.monitorState == .running)

        #expect(harness.model.status == nil)
        harness.model.togglePause()
        #expect(harness.model.isPaused)
        #expect(harness.model.status == .paused)
        harness.copyElsewhere("while paused")
        #expect(!harness.titles.contains("while paused"))
        harness.model.togglePause()
        #expect(!harness.model.isPaused)
    }

    /// Criterion C6: a blocked clipboard is stated, with the way to fix it.
    @Test func aBlockedClipboardGivesAStatusThatNamesTheFix() throws {
        let harness = try ClipboardHarness()
        harness.denied = true
        harness.model.monitor.tick()

        #expect(harness.model.status == .blocked)
        #expect(harness.model.status?.message.contains("Paste from Other Apps") == true)
        #expect(harness.model.status?.actionTitle == "Open Settings")
    }

    /// Pausing to copy something private must hold across a relaunch.
    @Test func aPauseIsRememberedAcrossLaunches() throws {
        let first = try ClipboardHarness()
        first.model.togglePause()
        #expect(first.defaults.bool(forKey: ClipboardModel.pausedKey))

        let relaunched = try ClipboardHarness(paused: true)
        #expect(relaunched.model.isPaused, "history resumed on its own after a relaunch")
        relaunched.copyElsewhere("copied after relaunch while paused")
        #expect(relaunched.titles.isEmpty)

        relaunched.model.togglePause()
        #expect(!relaunched.defaults.bool(forKey: ClipboardModel.pausedKey))
    }

    @Test func startingRemovesExpiredHistory() throws {
        let harness = try ClipboardHarness()
        try harness.store.record(.text("ancient"), at: Date().addingTimeInterval(-Double(ClipStore.historyDays + 1) * 86_400))
        try harness.store.record(.text("fresh"))

        harness.model.start()
        harness.model.monitor.stop()

        #expect(harness.titles == ["fresh"])
    }

    @Test func aBlankCollectionNameIsRefusedWithAMessage() throws {
        let harness = try ClipboardHarness()
        #expect(harness.model.createCollection(named: "  ") == nil)
        #expect(harness.model.problem == "A collection needs a name.")
        #expect(harness.model.collections.isEmpty)
    }

    /// Copying a capture from QuickShot must not also land in clipboard history.
    @Test func copyingACaptureIsNotRecordedAsHistory() throws {
        let harness = try ClipboardHarness()
        let capture = try harness.addCapture(named: "Screenshot D.png")

        harness.model.copy(.capture(capture))
        harness.model.monitor.tick()

        #expect(harness.pasteboard.data(forType: .png) != nil)
        #expect(harness.titles.isEmpty)
    }
}

/// Renders of the real clipboard window, drawn off screen for inspection.
@MainActor
@Suite(.serialized) struct ClipboardRenderTests {
    static let longText = (1...40).map { "Line \($0): the quick brown fox jumps over the lazy dog while the build finishes and the tests run." }.joined(separator: "\n")

    static func populated() throws -> ClipboardHarness {
        let harness = try ClipboardHarness()
        try harness.store.record(.text("git commit -m \"fix: captures land in the library\"", sourceApp: "com.apple.Terminal"),
                                 at: Date().addingTimeInterval(-400))
        try harness.store.record(.files([URL(fileURLWithPath: "/Users/example/Documents/Quarterly report final v3 (reviewed).pdf")]),
                                 at: Date().addingTimeInterval(-300))
        let picture = harness.folder.url.appendingPathComponent("picture.png")
        try writeRealPNG(to: picture, width: 800, height: 500, hue: 0.55)
        try harness.store.record(ClipCandidate(kind: .image, imageData: try Data(contentsOf: picture), pixelWidth: 800, pixelHeight: 500),
                                 at: Date().addingTimeInterval(-200))
        try harness.store.record(.text(longText, sourceApp: "com.apple.Safari"), at: Date().addingTimeInterval(-100))
        _ = try harness.addCapture(named: "Screenshot 2026-11-09 at 00.41.07.png")
        harness.model.createCollection(named: "Work")
        harness.model.createCollection(named: "Receipts")
        harness.model.reload()
        return harness
    }

    static func render(_ model: ClipboardModel, size: NSSize, name: String) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let window = ClipboardWindow.make(model: model)
        #expect(window.tabbingMode == .disallowed)
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        window.layoutIfNeeded()
        try await RenderTests.settle()
        window.layoutIfNeeded()
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try RenderTests.save(rep, as: name)
        return rep
    }

    @Test func historyWithALongTextSelectedAtTheDefaultSize() async throws {
        let harness = try Self.populated()
        harness.model.selection = harness.model.entries.first?.id
        #expect(harness.model.selectedEntry?.kindWord == "Text")

        let rep = try await Self.render(harness.model, size: LibraryLayout.defaultSize, name: "8-clipboard-text")
        #expect(rep.size.width == LibraryLayout.defaultSize.width)
        #expect(RenderTests.distinctColours(rep) > 8)
    }

    @Test func anImageSelectedAtTheSmallestSize() async throws {
        let harness = try Self.populated()
        harness.model.selection = harness.model.entries.first { $0.kindWord == "Image" }?.id

        let rep = try await Self.render(harness.model, size: LibraryLayout.minimumSize, name: "8-clipboard-image-smallest")
        #expect(rep.size.width == LibraryLayout.minimumSize.width)
        #expect(RenderTests.distinctColours(rep) > 8)
    }

    @Test func aBlockedClipboardWithNothingCopiedYet() async throws {
        let harness = try ClipboardHarness()
        harness.denied = true
        harness.model.monitor.tick()
        #expect(harness.model.monitorState == .blocked)

        let rep = try await Self.render(harness.model, size: LibraryLayout.defaultSize, name: "8-clipboard-blocked-empty")
        #expect(RenderTests.distinctColours(rep) > 4)
    }
}
