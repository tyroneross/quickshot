import AppKit
import Foundation
import QuickShotCore
import Testing
import TestSupport
@testable import QuickShot

/// Copy, Annotate and Move to Trash on the library, with the editor and the
/// clipboard replaced by recorders.
@MainActor
@Suite struct LibraryActionsTests {
    static func withCaptures(_ count: Int) throws -> Harness {
        let harness = try Harness(tool: Tool.writesPNG)
        try RenderTests.addCaptures(count, to: harness)
        harness.model.start()
        #expect(harness.model.items.count == count)
        return harness
    }

    @Test func trashingKeepsASelectionOnTheNextItemOrTheLast() throws {
        let harness = try Self.withCaptures(3)
        let model = harness.model
        let (first, second, third) = (model.items[0], model.items[1], model.items[2])

        model.selection = second.id
        model.trash(second)
        #expect(model.items.map(\.id) == [first.id, third.id])
        #expect(model.selection == third.id, "the item that took the trashed one's place is selected")

        model.trash(third)
        #expect(model.selection == first.id, "at the end, the previous item is selected")

        model.trash(first)
        #expect(model.items.isEmpty && model.selection == nil)
    }

    @Test func trashingAnUnselectedItemLeavesTheSelectionAlone() throws {
        let harness = try Self.withCaptures(3)
        let model = harness.model
        model.selection = model.items[0].id
        model.trash(model.items[2])
        #expect(model.selection == model.items[0].id)
    }

    @Test func annotateOpensTheEditorForAPictureAndReportsAFileThatHasGone() throws {
        let harness = try Self.withCaptures(2)
        let model = harness.model
        var opened: [CaptureItem] = []
        model.openEditor = { opened.append($0) }

        model.annotate(model.items[0])
        #expect(opened == [model.items[0]])
        #expect(model.notice == nil)

        let gone = model.items[1]
        try FileManager.default.removeItem(at: gone.url)
        model.annotate(gone)
        #expect(opened.count == 1, "nothing opens for a missing file")
        guard case .problem(let text, let retry)? = model.notice else { Issue.record("expected a notice"); return }
        #expect(text == "Could not open \(gone.url.lastPathComponent): the file has moved or been deleted.")
        #expect(retry == nil)
        #expect(model.items.count == 1, "the list was re-read")
    }

    @Test func aMarkedCopyIsSelectedAndShownAsCopied() throws {
        let harness = try Self.withCaptures(1)
        let model = harness.model
        let marked = try Annotator.save(model.items[0].url, boxes: [CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)])

        model.didMark(marked)
        #expect(model.items.count == 2)
        #expect(model.selection == marked.lastPathComponent)
        #expect(model.copiedItem == marked.lastPathComponent)
        #expect(try #require(model.selectedItem).isMarked)
    }

    @Test func aFailedCopyOffersTryAgain() throws {
        let harness = try Self.withCaptures(1)
        let model = harness.model
        let item = model.items[0]
        let allowed = AccessBox(granted: false)
        model.copyToClipboard = { _ in allowed.screenAccess.isGranted() }

        model.copy(item)
        guard case .problem(let text, let retry?)? = model.notice else { Issue.record("expected a notice with Try Again"); return }
        #expect(text == "Could not copy \(item.url.lastPathComponent) to the clipboard.")
        #expect(model.copiedItem == nil)

        allowed.setGranted(true)
        retry.action()
        #expect(model.notice == nil)
        #expect(model.copiedItem == item.id)
    }

    @Test func aFailedTrashOffersTryAgain() throws {
        let scratch = try TempFolder()
        let captures = try TempFolder()
        // Refuses until told otherwise; a lock box, as the closure is Sendable.
        let gate = AccessBox(granted: false)
        let library = CaptureLibrary(directory: captures.url, remove: { url in
            guard gate.screenAccess.isGranted() else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        let model = AppModel(library: library, runner: CaptureRunner(executable: try scratch.script(Tool.writesPNG), scratchRoot: scratch.url),
                             screenAccess: AccessBox(granted: true).screenAccess,
                             defaults: UserDefaults(suiteName: "QuickShotTests.\(UUID().uuidString)")!)
        try writeRealPNG(to: captures.url.appendingPathComponent("Screenshot 2026-11-09 at 17.20.00.png"), hue: 0.3)
        model.start()
        let item = try #require(model.items.first)

        model.trash(item)
        #expect(model.items.count == 1)
        guard case .problem(_, let retry?)? = model.notice else { Issue.record("expected Try Again"); return }

        gate.setGranted(true)
        retry.action()
        #expect(model.items.isEmpty && model.notice == nil)
    }
}
