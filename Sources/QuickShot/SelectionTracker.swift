import AppKit

/// Works out where an Area screenshot was taken, so the flash can frame it.
/// The system crosshair does not report its rectangle, so this watches the
/// mouse while the crosshair is up: the press and the release are the two
/// corners; a plain click is window mode, and the window under the pointer
/// is the area. Mouse events need no permission to observe.
@MainActor
final class SelectionTracker {
    private var monitors: [Any] = []
    private var pressed: NSPoint?
    private var released: NSPoint?
    /// A drag shorter than this is a click: window mode.
    static let clickTolerance: CGFloat = 4

    func start() {
        stop()
        pressed = nil
        released = nil
        monitors = [
            // The position is read in the callback itself, before the pointer
            // can move on. Global monitors are delivered on the main thread.
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.pressed = NSEvent.mouseLocation }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                MainActor.assumeIsolated { self?.released = NSEvent.mouseLocation }
            },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    /// The captured area in screen coordinates, or `nil` when the mouse was
    /// not seen (a cancelled capture, or a keyboard-only one).
    func selection() -> NSRect? {
        guard let pressed, let released else { return nil }
        let rect = Self.rect(from: pressed, to: released)
        if rect.width >= Self.clickTolerance || rect.height >= Self.clickTolerance { return rect }
        return Self.window(at: released)
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
