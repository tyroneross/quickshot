import AppKit

/// Works out where an Area screenshot was taken, so the flash can frame it.
/// The system crosshair does not report its rectangle, and it swallows the
/// mouse events before any observer in another app sees them (measured
/// 2026-11-09). So, while the crosshair is up, this polls the pointer and
/// the button state, which need no permission: the press and the release are
/// the two corners; a plain click is window mode, and the window under the
/// pointer is the area.
@MainActor
final class SelectionTracker {
    private var timer: Timer?
    private var wasDown = false
    private(set) var pressed: NSPoint?
    private(set) var released: NSPoint?
    /// A drag shorter than this is a click: window mode.
    static let clickTolerance: CGFloat = 4
    /// Polling rate. The pointer can move a few points between the real
    /// press and the poll; the captured image's own size corrects the rest.
    static let interval: TimeInterval = 1.0 / 120

    func start() {
        stop()
        pressed = nil
        released = nil
        wasDown = NSEvent.pressedMouseButtons & 1 != 0
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let isDown = NSEvent.pressedMouseButtons & 1 != 0
        if isDown, !wasDown { pressed = NSEvent.mouseLocation; released = nil }
        if !isDown, wasDown, pressed != nil { released = NSEvent.mouseLocation }
        wasDown = isDown
    }

    /// The captured area in screen coordinates, or `nil` when the mouse was
    /// not seen (a cancelled capture, or a keyboard-only one). `size`, the
    /// captured image's size in points, makes the frame exact: the corner
    /// where the drag began is kept and the rest follows the image.
    func selection(imageSize size: NSSize? = nil) -> NSRect? {
        guard let pressed, let released else { return nil }
        var rect = Self.rect(from: pressed, to: released)
        guard rect.width >= Self.clickTolerance || rect.height >= Self.clickTolerance else {
            return Self.window(at: released)
        }
        if let size, size.width > 0, size.height > 0 {
            let x = released.x >= pressed.x ? pressed.x : pressed.x - size.width
            let y = released.y >= pressed.y ? pressed.y : pressed.y - size.height
            rect = NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        return rect
    }

    static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The frontmost ordinary window under a point, in screen coordinates.
    static func window(at point: NSPoint) -> NSRect? {
        guard let screenHeight = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            // Window bounds use a top-left origin; screen points a bottom-left one.
            let rect = NSRect(x: x, y: screenHeight - y - h, width: w, height: h)
            if rect.contains(point) { return rect }
        }
        return nil
    }
}
