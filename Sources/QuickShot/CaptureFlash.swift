import AppKit

/// A quick white flash over every screen when a screenshot is taken, the
/// Mac's own signal that the picture exists. With Reduce Motion on, a steady
/// border around each screen for a moment instead of a fade.
@MainActor
enum CaptureFlash {
    static let flashOpacity: CGFloat = 0.35
    static let fadeSeconds: TimeInterval = 0.3
    static let borderSeconds: TimeInterval = 0.4
    static let borderWidth: CGFloat = 6

    static func show(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.hasShadow = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            if reduceMotion {
                view.layer?.borderColor = NSColor.controlAccentColor.cgColor
                view.layer?.borderWidth = borderWidth
            } else {
                view.layer?.backgroundColor = NSColor.white.cgColor
                window.alphaValue = flashOpacity
            }
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
}
