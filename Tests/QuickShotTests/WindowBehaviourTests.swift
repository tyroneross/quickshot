import AppKit
import QuickShotCore
import SwiftUI
import TestSupport
import Testing
@testable import QuickShot

/// Drives the real library window with real mouse events and real frame
/// changes, off screen: what a click and a resize do, not what the model
/// would do if asked.
@MainActor
@Suite(.serialized) struct WindowBehaviourTests {
    static func makeWindow(captures: Int, sizeDefaults: UserDefaults? = nil, harness: Harness? = nil) async throws -> (harness: Harness, window: NSWindow) {
        _ = NSApplication.shared
        let harness = try harness ?? Harness(tool: Tool.writesPNG)
        for index in 0..<captures {
            try writeRealPNG(to: harness.captures.url.appendingPathComponent("Shot \(index).png"), hue: 0.1 * CGFloat(index + 1))
        }
        harness.model.reload()
        let window = LibraryWindow.make(model: harness.model, sizeDefaults: sizeDefaults)
        // Mouse events are only delivered to a window that is in the window
        // list; it is fully transparent so nothing is seen.
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        try await RenderTests.settle()
        window.layoutIfNeeded()
        return (harness, window)
    }

    /// A press and release at a point given from the content's top left.
    static func click(_ window: NSWindow, x: CGFloat, fromTop: CGFloat, count: Int) async throws {
        let height = window.contentRect(forFrameRect: window.frame).height
        let point = NSPoint(x: x, y: height - fromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// The middle of the first card's thumbnail.
    static let firstCard = (x: Layout.padding + 70, fromTop: Layout.captureBarHeight + 60)

    @Test func aClickOnACardSelectsIt() async throws {
        let (harness, window) = try await Self.makeWindow(captures: 2)
        try await Self.click(window, x: Self.firstCard.x, fromTop: Self.firstCard.fromTop, count: 1)
        try await harness.waitUntil { harness.model.selection != nil }
        #expect(harness.model.selection == harness.model.items.first?.id)
    }

    @Test func aDoubleClickOnAPictureOpensItsEditor() async throws {
        let (harness, window) = try await Self.makeWindow(captures: 2)
        var opened: [CaptureItem.ID] = []
        harness.model.openEditor = { opened.append($0.id) }
        try await Self.click(window, x: Self.firstCard.x, fromTop: Self.firstCard.fromTop, count: 1)
        try await Self.click(window, x: Self.firstCard.x, fromTop: Self.firstCard.fromTop, count: 2)
        try await harness.waitUntil { !opened.isEmpty }
        #expect(opened == [try #require(harness.model.items.first).id])
    }

    /// Tiling, a window manager, or a script sets the frame without a live
    /// resize. The size must stay, also when the captures change afterwards.
    @Test func aSizeSetWithoutDraggingIsKept() async throws {
        let (harness, window) = try await Self.makeWindow(captures: 2)
        let chosen = NSSize(width: 900, height: 700)
        window.setContentSize(chosen)
        try await Task.sleep(for: .milliseconds(300))
        try writeRealPNG(to: harness.captures.url.appendingPathComponent("Shot new.png"), hue: 0.7)
        harness.model.reload()
        try await RenderTests.settle()
        #expect(RenderTests.contentSize(window) == chosen)
    }

    /// Before the person sizes it, the window still follows its content.
    @Test func anUntouchedWindowGrowsWithItsCaptures() async throws {
        let (harness, window) = try await Self.makeWindow(captures: 0)
        let empty = RenderTests.contentSize(window)
        for index in 0..<3 {
            try writeRealPNG(to: harness.captures.url.appendingPathComponent("Shot \(index).png"), hue: 0.2 * CGFloat(index + 1))
        }
        harness.model.reload()
        try await RenderTests.settle()
        #expect(RenderTests.contentSize(window).height > empty.height)
    }

    /// The chosen size is remembered: the next launch does not shrink the
    /// window back to its content.
    @Test func aChosenSizeSurvivesARelaunch() async throws {
        let suite = "QuickShotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (harness, first) = try await Self.makeWindow(captures: 2, sizeDefaults: defaults)
        first.setContentSize(NSSize(width: 900, height: 700))
        #expect(defaults.bool(forKey: LibraryWindow.ownerSizedKey))
        first.close()

        let (_, second) = try await Self.makeWindow(captures: 0, sizeDefaults: defaults, harness: harness)
        let chosen = NSSize(width: 800, height: 600)
        second.setContentSize(chosen)
        try writeRealPNG(to: harness.captures.url.appendingPathComponent("Shot later.png"), hue: 0.5)
        harness.model.reload()
        try await RenderTests.settle()
        #expect(RenderTests.contentSize(second) == chosen)
    }

    /// An owner-sized window opens at the size it was left, not at whatever
    /// the content would ask for.
    @Test func anOwnerSizedWindowReopensAtItsSize() async throws {
        let suite = "QuickShotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (harness, first) = try await Self.makeWindow(captures: 2, sizeDefaults: defaults)
        let chosen = NSSize(width: 720, height: 540)
        first.setContentSize(chosen)
        first.close()

        let (_, second) = try await Self.makeWindow(captures: 0, sizeDefaults: defaults, harness: harness)
        #expect(RenderTests.contentSize(second) == chosen)
    }

    /// A window that only ever followed its content does so again next time,
    /// from the size the content needs now, not the size saved before.
    @Test func anUntouchedWindowReopensAtItsContentSize() async throws {
        let suite = "QuickShotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (many, first) = try await Self.makeWindow(captures: 6, sizeDefaults: defaults)
        let tall = RenderTests.contentSize(first)
        first.close()
        _ = many

        let (_, second) = try await Self.makeWindow(captures: 1, sizeDefaults: defaults)
        #expect(RenderTests.contentSize(second).height < tall.height)
        #expect(defaults.bool(forKey: LibraryWindow.ownerSizedKey) == false)
    }

    /// A window nobody has sized records nothing.
    @Test func contentSizingAloneIsNotRemembered() async throws {
        let suite = "QuickShotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (harness, _) = try await Self.makeWindow(captures: 1, sizeDefaults: defaults)
        try writeRealPNG(to: harness.captures.url.appendingPathComponent("Shot more.png"), hue: 0.5)
        try writeRealPNG(to: harness.captures.url.appendingPathComponent("Shot most.png"), hue: 0.6)
        harness.model.reload()
        try await RenderTests.settle()
        #expect(defaults.bool(forKey: LibraryWindow.ownerSizedKey) == false)
    }

    /// With the system set to prefer tabs, a new window joins an open one as
    /// a tab and takes its frame. The editor must open as its own window, at
    /// the picture's size, however small the library window is.
    @Test func theEditorOpensAsItsOwnWindowAtThePicturesSize() async throws {
        let (harness, library) = try await Self.makeWindow(captures: 1)
        let url = harness.captures.url.appendingPathComponent("Wide.png")
        try writeRealPNG(to: url, width: 1200, height: 800, hue: 0.4)
        harness.model.reload()
        let item = try #require(harness.model.items.first { $0.url.lastPathComponent == "Wide.png" })
        let editor = try AnnotationEditor(item: item)
        let window = AnnotateWindow.make(editor: editor)
        let expected = AnnotateWindow.contentSize(for: editor.picture.pointSize, on: NSScreen.main)
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))

        #expect(window.tabbingMode == .disallowed)
        #expect(library.tabbingMode == .disallowed)
        #expect((window.tabGroup?.windows.count ?? 1) == 1)
        #expect(RenderTests.contentSize(window) == expected)
        #expect(RenderTests.contentSize(window).width > RenderTests.contentSize(library).width)
    }
}
