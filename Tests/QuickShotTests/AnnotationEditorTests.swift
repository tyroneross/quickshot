import AppKit
import Foundation
import QuickShotCore
import Testing
import TestSupport
@testable import QuickShot

@MainActor
@Suite struct AnnotationEditorTests {
    /// A real 640x400 picture in its own folder, and the editor on it with
    /// the clipboard replaced by a recorder.
    @MainActor
    final class Bench {
        let folder: TempFolder
        let item: CaptureItem
        let editor: AnnotationEditor
        private(set) var copies: [(data: Data, file: URL?)] = []
        private(set) var finished: [URL] = []

        init() throws {
            folder = try TempFolder()
            let url = folder.url.appendingPathComponent("Screenshot 2026-11-09 at 17.10.00.png")
            try writeRealPNG(to: url, hue: 0.1)
            item = CaptureItem(url: url, kind: .image, created: Date(), byteCount: 1)
            editor = try AnnotationEditor(item: item)
            editor.copy = { [unowned self] data, file in copies.append((data, file)); return true }
            editor.onFinished = { [unowned self] in finished.append($0) }
        }

        var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()) ?? [] }
    }

    static let big = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    static let small = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    @Test func boxesAreAddedUndoneRedoneAndCleared() throws {
        let bench = try Bench()
        let editor = bench.editor
        #expect(editor.status == "Drag over content to box it")
        #expect(!editor.canFinish && !editor.canUndo && !editor.canRedo)

        #expect(editor.add(Self.big) && editor.add(Self.small))
        #expect(editor.boxes.count == 2 && editor.status.isEmpty && editor.canFinish)
        editor.undo()
        #expect(editor.boxes == [Self.big] && editor.canRedo)
        editor.redo()
        #expect(editor.boxes == [Self.big, Self.small])
        editor.clear()
        #expect(editor.boxes.isEmpty && !editor.canFinish)
        editor.undo()
        #expect(editor.boxes.count == 2, "Clear is one step to undo")
        editor.add(CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        #expect(!editor.canRedo, "a new box ends the redo trail")
    }

    @Test func aSlipOfTheMouseIsNotABoxAndABoxOffThePictureIsClamped() throws {
        let editor = try Bench().editor
        // 640 pt wide: 0.005 is 3.2 pt.
        #expect(!editor.add(CGRect(x: 0.2, y: 0.2, width: 0.005, height: 0.5)))
        #expect(editor.boxes.isEmpty && !editor.canUndo)
        #expect(editor.add(CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5)))
        let box = try #require(editor.boxes.first)
        #expect(abs(box.maxX - 1) < 0.0001 && abs(box.maxY - 1) < 0.0001 && abs(box.minX - 0.9) < 0.0001)
    }

    @Test func clickingSelectsTheSmallestBoxUnderThePointerAndDeleteRemovesIt() throws {
        let editor = try Bench().editor
        editor.add(Self.big)
        editor.add(Self.small)
        editor.select(at: CGPoint(x: 0.5, y: 0.5))
        #expect(editor.selected == 1)
        #expect(editor.status == "Box 2 selected. Delete removes it")
        editor.removeSelected()
        #expect(editor.boxes == [Self.big] && editor.selected == nil)
        editor.select(at: CGPoint(x: 0.95, y: 0.95))
        #expect(editor.selected == nil, "a click outside every box selects nothing")
        editor.select(at: CGPoint(x: 0.5, y: 0.5))
        editor.add(CGRect(x: 0, y: 0, width: 0.05, height: 0.05))
        #expect(editor.selected == nil, "a change drops the selection")
    }

    @Test func copySavesAMarkedCopyPutsItOnTheClipboardAndReportsIt() throws {
        let bench = try Bench()
        let editor = bench.editor
        #expect(!editor.finish(), "nothing to copy yet")
        #expect(bench.copies.isEmpty && bench.finished.isEmpty)

        editor.add(Self.big)
        #expect(editor.finish())
        let saved = try #require(bench.finished.first)
        #expect(saved.lastPathComponent == "Screenshot 2026-11-09 at 17.10.00 (marked).png")
        #expect(bench.copies.count == 1 && bench.copies[0].file == saved)
        #expect(CaptureFormat.detect(saved)?.fileExtension == "png")
        #expect(try Data(contentsOf: saved) == bench.copies[0].data, "the clipboard holds the saved bytes")
        #expect(editor.problem == nil)
        #expect(bench.files == ["Screenshot 2026-11-09 at 17.10.00 (marked).png", "Screenshot 2026-11-09 at 17.10.00.png"])
    }

    @Test func aFailedSaveStillCopiesAndSaysSo() throws {
        let bench = try Bench()
        let editor = bench.editor
        editor.write = { _, _ in throw Annotator.Failure.writeFailed }
        editor.add(Self.big)
        #expect(!editor.finish())
        #expect(bench.copies.count == 1 && bench.copies[0].file == nil, "the picture went to the clipboard without a file")
        #expect(editor.problem == "Not saved: the marked picture could not be written. The marked picture is on the clipboard.")
        #expect(bench.finished.isEmpty, "the editor stays open")
        #expect(editor.boxes == [Self.big])
    }

    @Test func anOriginalThatHasGoneIsNotGivenAnOrphanCopy() throws {
        let bench = try Bench()
        let editor = bench.editor
        editor.add(Self.big)
        try FileManager.default.removeItem(at: bench.item.url)
        #expect(!editor.finish())
        #expect(bench.copies.count == 1 && bench.copies[0].file == nil, "the picture still reaches the clipboard")
        #expect(editor.problem == "Not saved: the original has been moved or deleted. The marked picture is on the clipboard.")
        #expect(bench.files.isEmpty, "nothing is written beside a missing original")
    }

    @Test func aFailedCopyKeepsNothing() throws {
        let bench = try Bench()
        let editor = bench.editor
        editor.copy = { _, _ in false }
        editor.add(Self.big)
        #expect(!editor.finish())
        #expect(editor.problem == "Could not copy to the clipboard.")
        #expect(bench.finished.isEmpty)
        #expect(bench.files == ["Screenshot 2026-11-09 at 17.10.00.png"], "no half result on disk")
    }

    @Test func boxesKeptFromAClosedWindowAreAnnounced() throws {
        let editor = try Bench().editor
        editor.add(Self.big)
        editor.wasReopened = true
        #expect(editor.status == "1 box kept from before")
        editor.add(Self.small)
        #expect(editor.status.isEmpty)
    }

    @Test func theWindowFitsThePictureInsideTheScreen() {
        let screen = NSScreen.main
        let room = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let huge = AnnotateWindow.contentSize(for: CGSize(width: 6000, height: 4000), on: screen)
        #expect(huge.width <= room.width * 0.8 + 1 && huge.height <= room.height * 0.8 + 1)
        #expect(abs(huge.width / huge.height - 6024.0 / 4024.0) < 0.01, "proportions are kept")
        let tiny = AnnotateWindow.contentSize(for: CGSize(width: 100, height: 60), on: screen)
        #expect(tiny == AnnotateWindow.minimumSize, "small pictures are not enlarged; the window keeps its minimum")
        let modest = AnnotateWindow.contentSize(for: CGSize(width: 640, height: 400), on: screen)
        #expect(modest == NSSize(width: 664, height: 424), "a picture that fits is shown at its own size plus padding")
    }

    @Test func fittingAndMappingAgree() {
        let frame = BoxCanvas.fitted(CGSize(width: 640, height: 400), in: CGSize(width: 480, height: 360))
        #expect(frame == CGRect(x: 0, y: 30, width: 480, height: 300))
        let unit = BoxCanvas.unitRect(from: CGPoint(x: 120, y: 105), to: CGPoint(x: 360, y: 255), in: frame)
        #expect(abs(unit.minX - 0.25) < 0.001 && abs(unit.minY - 0.25) < 0.001 && abs(unit.width - 0.5) < 0.001 && abs(unit.height - 0.5) < 0.001)
        // Pointer positions outside the picture are clamped to its edge.
        let clamped = BoxCanvas.unitRect(from: CGPoint(x: -50, y: -50), to: CGPoint(x: 1000, y: 1000), in: frame)
        #expect(clamped == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
