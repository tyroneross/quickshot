import AppKit
import QuickShotCore
import SwiftUI
import TestSupport
import Testing
@testable import QuickShot

/// Renders the real views off screen (no Screen Recording permission needed)
/// and checks what they draw. Set QUICKSHOT_RENDER_DIR to keep the images.
@MainActor
@Suite(.serialized) struct RenderTests {
    /// The library view on the window surface. A view drawn off screen has no
    /// window behind it, so the surface is painted here to keep dark renders
    /// truthful.
    struct OnWindowSurface: View {
        var body: some View {
            LibraryView().background(Color(nsColor: .windowBackgroundColor))
        }
    }

    static func save(_ rep: NSBitmapImageRep, as name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["QUICKSHOT_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func settle() async throws {
        // Let thumbnails load and SwiftUI report its sizes.
        try await Task.sleep(for: .milliseconds(1500))
    }

    static func render(_ model: AppModel, size: CGSize, dark: Bool = false, name: String) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: OnWindowSurface().environment(model))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.appearance = window.appearance
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await settle()
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try save(rep, as: name)
        return rep
    }

    /// The real window with its real AppKit title bar, drawn from the window's
    /// frame view. The window is never ordered on screen.
    static func realWindow(_ model: AppModel, name: String) async throws -> (window: NSWindow, image: NSBitmapImageRep) {
        _ = NSApplication.shared
        let window = LibraryWindow.make(model: model)
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()
        try await settle()
        window.layoutIfNeeded()
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try save(rep, as: name)
        return (window, rep)
    }

    static func contentSize(_ window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    /// Counts distinct colours on a coarse grid; a blank render has one.
    static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                seen.insert("\(Int(c.redComponent * 31))-\(Int(c.greenComponent * 31))-\(Int(c.blueComponent * 31))")
            }
        }
        return seen.count
    }

    /// Reads the leading edge of the notice strip, which sits directly under
    /// the capture bar, and returns the tone whose colour it shows. The edge
    /// carries the tone, so this tells which notice (if any) was drawn.
    /// Expected colours come from `Banner.Tone`, the values the view draws.
    static func noticeTone(_ rep: NSBitmapImageRep, dark: Bool = false) throws -> Banner.Tone? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let y = Layout.captureBarHeight + 12
        let pixel = try #require(rep.colorAt(x: Int(1 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        // Compare by hue: an off-screen bitmap shifts RGB values slightly
        // (colour-space conversion) but keeps the hue. The window surface and
        // the 12% tints have low saturation, so they never match a tone.
        guard pixel.saturationComponent > 0.35 else { return nil }
        func hueDistance(to tone: Banner.Tone) -> Double {
            var hue = 0.0
            appearance.performAsCurrentDrawingAppearance {
                hue = (NSColor(tone.color).usingColorSpace(.sRGB) ?? .black).hueComponent
            }
            let d = abs(pixel.hueComponent - hue)
            return min(d, 1 - d)
        }
        let nearest = Banner.Tone.allCases.min { hueDistance(to: $0) < hueDistance(to: $1) }
        guard let nearest, hueDistance(to: nearest) < 0.05 else { return nil }
        return nearest
    }

    static func addCaptures(_ count: Int, to harness: Harness) throws {
        let hues: [CGFloat] = [0.58, 0.08, 0.33, 0.78, 0.95, 0.45]
        for index in 0..<count {
            let url = harness.captures.url.appendingPathComponent("Screenshot 2026-11-0\(8 - index % 8) at 22.41.0\(index).png")
            try writeRealPNG(to: url, hue: hues[index % hues.count])
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSinceNow: -Double(index + 1) * 3600)], ofItemAtPath: url.path)
        }
    }

    static func populated(_ harness: Harness) throws {
        try addCaptures(4, to: harness)
        // A file with a movie header but no frames: exercises the thumbnail fallback.
        let movie = try harness.captures.write(Fixture.mov, named: "Recording 2026-11-08 at 22.50.00.mov")
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: movie.path)
    }

    static let compact = CGSize(width: Layout.windowWidth, height: 430)

    // MARK: States

    @Test(arguments: [false, true])
    func launchWithoutPermissionShowsTheNotice(dark: Bool) async throws {
        let harness = try Harness(tool: Tool.writesPNG, granted: false)
        harness.model.start()

        let rep = try await Self.render(harness.model, size: Self.compact, dark: dark,
                                        name: "1-empty-permission-\(dark ? "dark" : "light")")
        #expect(try Self.noticeTone(rep, dark: dark) == .warning, "the permission notice was not drawn")
    }

    @Test(arguments: [false, true])
    func populatedLibraryWithASelection(dark: Bool) async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try Self.populated(harness)
        harness.model.start()
        #expect(harness.model.items.count == 5)
        harness.model.selection = harness.model.items[1].id

        let rep = try await Self.render(harness.model, size: Self.compact, dark: dark,
                                        name: "2-populated-selected-\(dark ? "dark" : "light")")
        #expect(Self.distinctColours(rep) > 12)
        #expect(try Self.noticeTone(rep, dark: dark) == nil, "a notice was drawn with nothing to report")
    }

    @Test func aLongProblemNoticeAtTheNarrowestWidth() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try Self.populated(harness)
        harness.model.start()
        harness.model.notice = .problem("Could not move Screenshot 2026-11-08 at 22.41.07.png to the Trash: the file is in use by another application and cannot be changed right now.")

        let rep = try await Self.render(harness.model, size: Self.compact, name: "3-narrow-long-problem")
        #expect(try Self.noticeTone(rep) == .error, "the problem notice was not drawn")
    }

    @Test func captureInProgress() async throws {
        let harness = try Harness(tool: Tool.waits)
        try Self.populated(harness)
        harness.model.start()
        harness.model.capture(.recording)
        try await harness.waitUntil { harness.toolRan }
        #expect(harness.model.isCapturing)

        // An unrelated notice must not sit under the recording status.
        harness.model.notice = .nothingSaved
        let rep = try await Self.render(harness.model, size: Self.compact, name: "4-capturing")
        harness.model.cancelCapture()
        try await harness.waitUntilIdle()
        #expect(try Self.noticeTone(rep) == nil, "a notice strip was drawn while a capture is running")
    }

    @Test func nothingSavedNotice() async throws {
        let harness = try Harness(tool: Tool.cancels)
        harness.model.start()
        harness.model.capture(.screenshot)
        try await harness.waitUntilIdle()
        #expect(harness.model.notice == .nothingSaved)

        let rep = try await Self.render(harness.model, size: Self.compact, name: "5-empty-nothing-saved")
        #expect(try Self.noticeTone(rep) == .info, "the nothing-saved notice was not drawn")
    }

    // MARK: The window takes only the space its content needs

    @Test func theWindowIsSmallWithNoCaptures() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()

        let (window, _) = try await Self.realWindow(harness.model, name: "6-window-empty")
        let size = Self.contentSize(window)
        print("window empty: \(Int(size.width))x\(Int(size.height))")

        #expect(size.width == Layout.windowWidth)
        #expect(size.height > Layout.captureBarHeight, "the hint under the buttons is missing")
        #expect(size.height < Layout.captureBarHeight + 110, "the empty window is taller than its content needs")
    }

    @Test func theWindowGrowsWithCapturesUpToTheScrollLimit() async throws {
        let one = try Harness(tool: Tool.writesPNG)
        try Self.addCaptures(1, to: one)
        one.model.start()
        let (oneWindow, _) = try await Self.realWindow(one.model, name: "6-window-one-capture")
        let oneRow = Self.contentSize(oneWindow)

        let many = try Harness(tool: Tool.writesPNG)
        try Self.addCaptures(12, to: many)
        many.model.start()
        many.model.selection = many.model.items[1].id
        let (manyWindow, image) = try await Self.realWindow(many.model, name: "6-window-many-captures")
        let capped = Self.contentSize(manyWindow)
        print("window one capture: \(Int(oneRow.width))x\(Int(oneRow.height)); twelve captures: \(Int(capped.width))x\(Int(capped.height))")

        #expect(oneRow.width == Layout.windowWidth)
        #expect(oneRow.height < Layout.captureBarHeight + 190, "one row of captures should not need two rows of space")
        #expect(capped.height > oneRow.height)
        #expect(capped.height == Layout.captureBarHeight + Layout.gridMaxIdealHeight, "twelve captures should stop at the scroll limit")
        #expect(Self.distinctColours(image) > 12)

        // With a selection, all four item actions fit in the narrow title bar.
        let toolbar = try #require(manyWindow.toolbar)
        #expect(toolbar.items.count == 4)
        #expect(toolbar.visibleItems?.count == toolbar.items.count, "an item action is hidden in the overflow menu")

        // Each title bar item keeps its name as the toolbar item label, which
        // the overflow menu shows. This does not prove what VoiceOver reads
        // from the symbol-only button: that needs an accessibility read of the
        // running app, and both the correct and the broken label style produce
        // the same value here (checked 2026-11-09).
        #expect(toolbar.items.map(\.label) == ["Copy", "Annotate", "Show in Finder", "Move to Trash"])
    }

    /// The window resizes as captures come and go, keeping its top edge still.
    @Test func theWindowFollowsItsContentWhileOpen() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()
        let (window, _) = try await Self.realWindow(harness.model, name: "7-window-before")
        let emptyHeight = Self.contentSize(window).height
        let top = window.frame.maxY

        try Self.addCaptures(3, to: harness)
        try await harness.waitUntil { harness.model.items.count == 3 }
        try await Self.settle()
        window.layoutIfNeeded()
        let grownHeight = Self.contentSize(window).height
        print("window follows content: \(Int(emptyHeight)) -> \(Int(grownHeight)); top \(Int(top)) -> \(Int(window.frame.maxY))")

        #expect(grownHeight > emptyHeight + 100, "the window did not grow when captures arrived")
        #expect(window.frame.maxY == top, "the window's top edge moved while it resized")
    }
}
