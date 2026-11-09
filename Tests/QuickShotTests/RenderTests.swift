import AppKit
import QuickShotCore
import SwiftUI
import TestSupport
import Testing
@testable import QuickShot

/// Renders the real views off screen (no Screen Recording permission needed)
/// and checks they draw. Set QUICKSHOT_RENDER_DIR to keep the images.
@MainActor
@Suite(.serialized) struct RenderTests {
    /// The window toolbar is an AppKit toolbar and cannot be drawn off screen,
    /// so the same toolbar views are laid out above the content instead.
    struct WindowFacsimile: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    CaptureControls()
                    Spacer(minLength: 8)
                    if let item = model.selectedItem { ItemActions(item: item) }
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                Divider()
                LibraryView()
            }
            // A view drawn off screen has no window behind it, so the window
            // surface is painted here to keep the dark render truthful.
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    static func render(_ model: AppModel, size: CGSize, dark: Bool, name: String) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: WindowFacsimile().environment(model))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.appearance = window.appearance
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let thumbnails load and SwiftUI settle.
        try await Task.sleep(for: .milliseconds(1500))
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["QUICKSHOT_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return rep
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

    static func populated(_ harness: Harness) throws {
        let names = [
            ("Screenshot 2026-11-08 at 22.41.07.png", 0.58), ("Screenshot 2026-11-08 at 21.15.40.png", 0.08),
            ("Screenshot 2026-11-07 at 09.02.11.png", 0.33), ("Screenshot 2026-11-06 at 16.48.59.png", 0.78),
        ]
        for (index, (name, hue)) in names.enumerated() {
            let url = harness.captures.url.appendingPathComponent(name)
            try writeRealPNG(to: url, hue: hue)
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSinceNow: -Double(index + 1) * 3600)], ofItemAtPath: url.path)
        }
        // A file with a movie header but no frames: exercises the thumbnail fallback.
        let movie = try harness.captures.write(Fixture.mov, named: "Recording 2026-11-08 at 22.50.00.mov")
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: movie.path)
    }

    @Test(arguments: [false, true])
    func launchWithoutPermissionShowsTheNoticeAndFirstSteps(dark: Bool) async throws {
        let harness = try Harness(tool: Tool.writesPNG, granted: false)
        harness.model.start()

        let rep = try await Self.render(harness.model, size: CGSize(width: 720, height: 572), dark: dark,
                                        name: "1-empty-permission-\(dark ? "dark" : "light")")
        #expect(Self.distinctColours(rep) > 4)
    }

    @Test(arguments: [false, true])
    func populatedLibraryWithASelection(dark: Bool) async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try Self.populated(harness)
        harness.model.start()
        #expect(harness.model.items.count == 5)
        harness.model.selection = harness.model.items[1].id

        let rep = try await Self.render(harness.model, size: CGSize(width: 720, height: 572), dark: dark,
                                        name: "2-populated-selected-\(dark ? "dark" : "light")")
        #expect(Self.distinctColours(rep) > 12)
    }

    @Test func smallestWindowWithALongErrorAndARecordingSelected() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try Self.populated(harness)
        harness.model.start()
        harness.model.selection = harness.model.items[0].id
        #expect(harness.model.selectedItem?.kind == .video)
        harness.model.notice = .problem("Could not move Screenshot 2026-11-08 at 22.41.07.png to the Trash: the file is in use by another application and cannot be changed right now.")

        let rep = try await Self.render(harness.model, size: CGSize(width: 480, height: 412), dark: false,
                                        name: "3-smallest-error-video")
        #expect(Self.distinctColours(rep) > 12)
    }

    /// The real window with its real AppKit toolbar, drawn from the window's
    /// frame view. The window is never ordered on screen.
    static func renderRealWindow(_ model: AppModel, window: NSWindow, contentSize: NSSize, name: String) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["QUICKSHOT_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("real window \(name): frame \(Int(frameView.bounds.width))x\(Int(frameView.bounds.height)), toolbar items \(window.toolbar?.items.count ?? -1), visible \(window.toolbar?.visibleItems?.count ?? -1)")
        return rep
    }

    /// At the default size every toolbar action is visible; nothing sits in
    /// the overflow menu.
    @Test func realWindowAtDefaultSizeShowsEveryToolbarAction() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try Self.populated(harness)
        harness.model.start()
        harness.model.selection = harness.model.items[1].id

        let window = LibraryWindow.make(model: harness.model)
        let rep = try await Self.renderRealWindow(
            harness.model, window: window, contentSize: LibraryWindow.defaultContentSize, name: "6-real-window-default")

        #expect(Self.distinctColours(rep) > 12)
        let toolbar = try #require(window.toolbar)
        #expect(toolbar.items.count == 6)
        #expect(toolbar.visibleItems?.count == toolbar.items.count, "an action is hidden in the overflow menu")
    }

    /// At the smallest size the capture buttons stay and item actions move to
    /// the system overflow menu instead of being clipped.
    @Test func realWindowAtSmallestSizeKeepsTheCaptureButtons() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try Self.populated(harness)
        harness.model.start()
        harness.model.selection = harness.model.items[1].id

        let window = LibraryWindow.make(model: harness.model)
        let rep = try await Self.renderRealWindow(
            harness.model, window: window, contentSize: LibraryWindow.minimumContentSize, name: "6-real-window-smallest")

        #expect(Self.distinctColours(rep) > 12)
        #expect((window.toolbar?.visibleItems?.count ?? 0) >= 2)
    }

    @Test func captureInProgress() async throws {
        let harness = try Harness(tool: Tool.waits)
        try Self.populated(harness)
        harness.model.start()
        harness.model.capture(.recording)
        try await harness.waitUntil { harness.toolRan }
        #expect(harness.model.isCapturing)

        let rep = try await Self.render(harness.model, size: CGSize(width: 720, height: 572), dark: false,
                                        name: "4-capturing")
        harness.model.cancelCapture()
        try await harness.waitUntilIdle()
        #expect(Self.distinctColours(rep) > 12)
    }

    @Test func nothingSavedNotice() async throws {
        let harness = try Harness(tool: Tool.cancels)
        harness.model.start()
        harness.model.capture(.screenshot)
        try await harness.waitUntilIdle()
        #expect(harness.model.notice == .nothingSaved)

        let rep = try await Self.render(harness.model, size: CGSize(width: 720, height: 572), dark: false,
                                        name: "5-empty-nothing-saved")
        #expect(Self.distinctColours(rep) > 4)
    }
}
