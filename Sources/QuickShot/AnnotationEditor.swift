import AppKit
import Observation
import QuickShotCore

/// The boxes drawn on one screenshot, with undo, and the one action that
/// turns them into a marked copy on the clipboard and in the library.
///
/// Boxes are unit rectangles (0…1 of the picture, origin top left). The view
/// maps pointer positions to them; `Annotator` draws them at full size.
@MainActor
@Observable
final class AnnotationEditor {
    let item: CaptureItem
    let picture: Annotator.Picture
    /// The picture for the view, at its point size.
    let image: NSImage

    private(set) var boxes: [CGRect] = []
    /// The box the person clicked, by index. Delete removes it.
    var selected: Int? {
        didSet { if let selected, !boxes.indices.contains(selected) { self.selected = nil } }
    }
    /// Why the last Copy did not finish, shown as written.
    var problem: String?
    /// True after the window was closed with boxes and opened again, until
    /// the boxes change: the status line says the boxes were kept.
    var wasReopened = false

    private var history: [[CGRect]] = []
    private var redoStack: [[CGRect]] = []

    /// Draws the boxes into the full-size picture as PNG bytes.
    @ObservationIgnored var render: ([CGRect]) throws -> Data
    /// Writes the bytes beside the original; returns the new file.
    @ObservationIgnored var write: (Data, URL) throws -> URL = { try Annotator.write($0, beside: $1) }
    /// Puts the bytes (and the file, when saved) on the clipboard.
    @ObservationIgnored var copy: (Data, URL?) -> Bool = { CaptureActions.copyPNG($0, file: $1) }
    /// Called with the saved file once Copy has fully succeeded.
    @ObservationIgnored var onFinished: (URL) -> Void = { _ in }

    init(item: CaptureItem) throws {
        self.item = item
        let picture = try Annotator.load(item.url)
        self.picture = picture
        image = NSImage(cgImage: picture.image, size: picture.pointSize)
        render = { boxes in try Annotator.pngData(Annotator.render(picture, boxes: boxes), dpi: picture.dpi) }
    }

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Copy needs something to copy: the plain picture is on the clipboard already.
    var canFinish: Bool { !boxes.isEmpty }

    /// What the toolbar says: how to begin, what is selected, or nothing.
    var status: String {
        if let selected { return "Box \(selected + 1) selected. Delete removes it" }
        if boxes.isEmpty { return "Drag over content to box it" }
        if wasReopened { return boxes.count == 1 ? "1 box kept from before" : "\(boxes.count) boxes kept from before" }
        return ""
    }

    /// Adds a box, unless it is a slip of the mouse. Returns whether it was added.
    @discardableResult
    func add(_ box: CGRect) -> Bool {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        // Only a box hanging off the picture is cut; one inside keeps its exact values.
        let clamped = unit.contains(box.standardized) ? box.standardized : box.standardized.intersection(unit)
        guard !clamped.isNull, Annotator.isUsable(clamped, in: picture.pointSize) else { return false }
        change { $0.append(clamped) }
        return true
    }

    func remove(at index: Int) {
        guard boxes.indices.contains(index) else { return }
        change { $0.remove(at: index) }
    }

    func removeSelected() {
        if let selected { remove(at: selected) }
    }

    func clear() {
        guard !boxes.isEmpty else { return }
        change { $0.removeAll() }
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        redoStack.append(boxes)
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        history.append(boxes)
        apply(next)
    }

    /// Selects the box under a unit point: the smallest one containing it.
    func select(at point: CGPoint) {
        selected = boxes.indices
            .filter { boxes[$0].contains(point) }
            .min { boxes[$0].width * boxes[$0].height < boxes[$1].width * boxes[$1].height }
    }

    /// Renders, saves beside the original and copies. The clipboard comes
    /// first in what is kept: a failed save still leaves the marked picture
    /// on the clipboard, and the editor stays open to say so.
    @discardableResult
    func finish() -> Bool {
        guard canFinish else { return false }
        let data: Data
        do {
            data = try render(boxes)
        } catch {
            problem = "Could not draw the boxes: \(error)."
            return false
        }
        var saved: URL?
        var saveProblem: String?
        if !FileManager.default.fileExists(atPath: item.url.path) {
            // The original was trashed meanwhile: no orphan file beside a gap.
            saveProblem = "Not saved: the original has been moved or deleted. The marked picture is on the clipboard."
        } else {
            do {
                saved = try write(data, item.url)
            } catch {
                saveProblem = "Not saved: \(error). The marked picture is on the clipboard."
            }
        }
        guard copy(data, saved) else {
            // Nothing is kept: a retry would otherwise file a second copy.
            if let saved { try? FileManager.default.removeItem(at: saved) }
            problem = "Could not copy to the clipboard."
            return false
        }
        if let saveProblem {
            problem = saveProblem
            return false
        }
        problem = nil
        if let saved { onFinished(saved) }
        return true
    }

    private func change(_ edit: (inout [CGRect]) -> Void) {
        history.append(boxes)
        redoStack.removeAll()
        var next = boxes
        edit(&next)
        apply(next)
    }

    private func apply(_ next: [CGRect]) {
        boxes = next
        selected = nil
        wasReopened = false
    }
}

extension CaptureItem {
    /// A marked copy made by the editor.
    var isMarked: Bool { Annotator.isMarked(url) }
}
