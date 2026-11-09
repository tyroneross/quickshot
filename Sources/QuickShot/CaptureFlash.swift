import AppKit

/// A quick frame around what was just captured: a border that fades, or,
/// with Reduce Motion on, a steady border for a moment. Full Screen frames
/// every screen; Area frames the area.
@MainActor
enum CaptureFlash {
    static let fadeSeconds: TimeInterval = 0.45
    static let borderSeconds: TimeInterval = 0.5
    static let borderWidth: CGFloat = 4

    /// Frames each screen.
    static func showScreens(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        for screen in NSScreen.screens { show(around: screen.frame, reduceMotion: reduceMotion) }
    }

    /// Frames one rectangle in screen coordinates. The border sits just
    /// outside the rectangle, so the picture itself is not covered.
    static func show(around rect: NSRect, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        let frame = rect.insetBy(dx: -borderWidth, dy: -borderWidth)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = borderWidth
        view.layer?.cornerRadius = borderWidth
        window.contentView = view
        window.orderFrontRegardless()
        if reduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + borderSeconds) { window.close() }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeSeconds
                window.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor in window.close() } })
        }
    }
}
