import AppKit
import QuickShotCore
import SwiftUI

/// The picture with its boxes. Drag draws a box; click selects one; the
/// toolbar undoes, clears and copies.
struct AnnotateView: View {
    @Bindable var editor: AnnotationEditor

    var body: some View {
        VStack(spacing: 0) {
            if let problem = editor.problem {
                Banner(tone: .error, text: problem, onDismiss: { editor.problem = nil })
            }
            BoxCanvas(editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Layout.padding)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(editor.status)
                    .font(.subheadline)
                    .foregroundStyle(Color.supportingText)
                    .lineLimit(1)
                    .accessibilityIdentifier("annotate-status")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!editor.canUndo)
                    .help("Undo (Command Z)")
                    .accessibilityIdentifier("annotate-undo")
                Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
                    .help("Redo (Shift Command Z)")
                    .accessibilityIdentifier("annotate-redo")
                Button("Clear", systemImage: "eraser") { editor.clear() }
                    .disabled(editor.boxes.isEmpty)
                    .help("Remove every box")
                    .accessibilityIdentifier("annotate-clear")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Copy") { editor.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!editor.canFinish)
                    .help("Save a marked copy to the library and put it on the clipboard (Command Return)")
                    .accessibilityIdentifier("annotate-copy")
            }
        }
        // Command C copies too; the toolbar button carries Command Return.
        .background {
            Button("Copy") { editor.finish() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!editor.canFinish)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// The picture scaled to fit, with the boxes drawn over it in the same
/// proportions the saved file gets.
struct BoxCanvas: View {
    @Bindable var editor: AnnotationEditor
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @FocusState private var focused: Bool

    /// Where the picture sits inside `size`, keeping its proportions.
    static func fitted(_ picture: CGSize, in size: CGSize) -> CGRect {
        guard picture.width > 0, picture.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / picture.width, size.height / picture.height)
        let fit = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
    }

    /// A rectangle between two points, in unit coordinates of `frame`.
    static func unitRect(from a: CGPoint, to b: CGPoint, in frame: CGRect) -> CGRect {
        func unit(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max((p.x - frame.minX) / frame.width, 0), 1),
                    y: min(max((p.y - frame.minY) / frame.height, 0), 1))
        }
        let p = unit(a), q = unit(b)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fitted(editor.picture.pointSize, in: geometry.size)
            ZStack {
                Image(nsImage: editor.image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                Canvas { context, _ in
                    draw(in: &context, frame: frame)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .pointerStyle(.rectSelection)
            .gesture(drag(frame: frame))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onDeleteCommand { editor.removeSelected() }
            .onAppear { focused = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(editor.boxes.isEmpty ? "Screenshot, no boxes" : "Screenshot, \(editor.boxes.count) \(editor.boxes.count == 1 ? "box" : "boxes")")
        .accessibilityChildren {
            ForEach(editor.boxes.indices, id: \.self) { index in
                Rectangle()
                    .accessibilityLabel("Box \(index + 1)")
                    .accessibilityAction(named: "Remove") { editor.remove(at: index) }
            }
        }
        .accessibilityIdentifier("annotate-canvas")
    }

    private func drag(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                defer { dragStart = nil; dragCurrent = nil }
                let box = Self.unitRect(from: value.startLocation, to: value.location, in: frame)
                // A click, or a slip too small to be a box, selects instead.
                if !editor.add(box) {
                    editor.select(at: Self.unitRect(from: value.location, to: value.location, in: frame).origin)
                }
            }
    }

    private func draw(in context: inout GraphicsContext, frame: CGRect) {
        // One on-screen point per picture point at this size.
        let k = frame.width / max(editor.picture.pointSize.width, 1)
        for (index, box) in editor.boxes.enumerated() {
            drawBox(box, number: index + 1, selected: editor.selected == index, in: &context, frame: frame, k: k)
        }
        if let dragStart, let dragCurrent {
            let live = Self.unitRect(from: dragStart, to: dragCurrent, in: frame)
            if live.width > 0, live.height > 0 {
                drawBox(live, number: editor.boxes.count + 1, selected: false, in: &context, frame: frame, k: k)
            }
        }
    }

    static let boxColor = Color(.sRGB, red: Annotator.boxRed, green: Annotator.boxGreen, blue: Annotator.boxBlue)

    private func drawBox(_ box: CGRect, number: Int, selected: Bool, in context: inout GraphicsContext, frame: CGRect, k: CGFloat) {
        let rect = CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + box.minY * frame.height,
                          width: box.width * frame.width, height: box.height * frame.height)
        let path = Path(roundedRect: rect, cornerRadius: Annotator.cornerRadius * k)
        let stroke = Annotator.strokeWidth * k
        context.stroke(path, with: .color(.white.opacity(Annotator.haloOpacity)), lineWidth: stroke + 2 * Annotator.haloWidth * k)
        // The selected box is dashed on screen only: the saved file is never dashed.
        let style = StrokeStyle(lineWidth: stroke, lineJoin: .round, dash: selected ? [stroke * 3, stroke * 2] : [])
        context.stroke(path, with: .color(Self.boxColor), style: style)

        let diameter = Annotator.badgeDiameter * k
        // The renderer clamps in picture coordinates, bottom-up; here y grows
        // downward, so the corner is (minX, minY) in picture-local terms.
        let local = Annotator.badgeCentre(
            for: CGRect(x: rect.minX - frame.minX, y: 0, width: rect.width, height: rect.minY - frame.minY),
            diameter: diameter, in: frame.size)
        let centre = CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
        let outer = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
        context.fill(Path(ellipseIn: outer), with: .color(.white))
        context.fill(Path(ellipseIn: outer.insetBy(dx: Annotator.badgeBorder * k, dy: Annotator.badgeBorder * k)), with: .color(Self.boxColor))
        context.draw(
            Text(String(number)).font(.system(size: Annotator.badgeFontSize * k, weight: .bold)).foregroundStyle(.white),
            at: centre)
    }
}

/// One window per picture. Esc and Command W close it and keep the boxes;
/// the editor itself lives as long as the window.
@MainActor
final class AnnotateWindow: NSWindow {
    static let minimumSize = NSSize(width: 480, height: 360)

    static func make(editor: AnnotationEditor) -> AnnotateWindow {
        let hosting = NSHostingController(rootView: AnnotateView(editor: editor))
        hosting.sceneBridgingOptions = [.toolbars]
        let window = AnnotateWindow(contentViewController: hosting)
        window.title = editor.item.url.lastPathComponent
        window.representedURL = editor.item.url
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumSize
        window.setContentSize(Self.contentSize(for: editor.picture.pointSize, on: NSScreen.main))
        window.center()
        return window
    }

    /// The picture at its own size, inside 80% of the screen, never below the
    /// minimum and never enlarged.
    static func contentSize(for picture: CGSize, on screen: NSScreen?) -> NSSize {
        let room = (screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900))
        let limit = NSSize(width: room.width * 0.8, height: room.height * 0.8)
        let padded = CGSize(width: picture.width + 2 * Layout.padding, height: picture.height + 2 * Layout.padding)
        let scale = min(1, limit.width / max(padded.width, 1), limit.height / max(padded.height, 1))
        return NSSize(width: max(minimumSize.width, (padded.width * scale).rounded()),
                      height: max(minimumSize.height, (padded.height * scale).rounded()))
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Command W, for an app without a File menu of its own.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}
