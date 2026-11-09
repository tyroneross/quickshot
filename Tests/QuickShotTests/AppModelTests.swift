import AppKit
import Foundation
import QuickShotCore
import TestSupport
import Testing
@testable import QuickShot

@MainActor
@Suite struct AppModelTests {
    @Test func aCaptureIsFiledListedAndSelected() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()

        harness.model.capture(.screenshot)
        #expect(harness.model.isCapturing)
        try await harness.waitUntilIdle()

        #expect(harness.model.items.count == 1)
        let item = try #require(harness.model.items.first)
        #expect(item.kind == .image)
        #expect(item.url.lastPathComponent.hasPrefix("Screenshot "))
        #expect(item.url.deletingLastPathComponent().standardizedFileURL == harness.captures.url.standardizedFileURL)
        #expect(harness.model.selection == item.id)
        #expect(harness.model.notice == nil)
    }

    @Test func theLibraryWindowHidesDuringACaptureAndReturnsAfter() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()

        harness.model.capture(.screenshot)
        #expect(!harness.windowVisible, "the window must be out of the picture while the picker is open")
        try await harness.waitUntilIdle()

        #expect(harness.windowEvents == ["hide", "show"])
        #expect(harness.windowVisible)
    }

    @Test func withoutScreenAccessNothingIsCapturedAndThePersonIsTold() async throws {
        let harness = try Harness(tool: Tool.writesPNG, granted: false)
        harness.model.start()
        #expect(harness.model.notice == .permissionNeeded, "the need is stated at launch")
        #expect(harness.access.requests == 0, "no system prompt until a capture is asked for")

        harness.model.capture(.screenshot)
        try await Task.sleep(for: .milliseconds(200))

        #expect(!harness.model.isCapturing)
        #expect(!harness.toolRan, "the tool must not run without access")
        #expect(harness.access.requests == 1)
        #expect(harness.model.notice == .permissionNeeded)
        #expect(harness.model.items.isEmpty)
        #expect(harness.windowEvents == ["show"])
    }

    @Test func thePermissionNoticeClearsOnceAccessIsGranted() throws {
        let harness = try Harness(tool: Tool.writesPNG, granted: false)
        harness.model.start()

        harness.model.refreshAccess()
        #expect(harness.model.notice == .permissionNeeded)

        harness.access.setGranted(true)
        harness.model.refreshAccess()
        #expect(harness.model.notice == nil)
    }

    @Test func aCancelledCaptureSaysNothingWasSavedAndRestoresTheWindow() async throws {
        let harness = try Harness(tool: Tool.cancels, windowVisible: true)
        harness.model.start()

        harness.model.capture(.recording)
        try await harness.waitUntilIdle()

        #expect(harness.model.notice == .nothingSaved)
        #expect(harness.model.items.isEmpty)
        #expect(harness.windowEvents == ["hide", "show"])
    }

    @Test func aCancelledCaptureLeavesAClosedWindowClosed() async throws {
        let harness = try Harness(tool: Tool.cancels, windowVisible: false)
        harness.model.start()

        harness.model.capture(.screenshot)
        try await harness.waitUntilIdle()

        #expect(harness.windowEvents == ["hide"])
        #expect(!harness.windowVisible)
    }

    @Test func aFailedCaptureShowsTheToolsOwnMessage() async throws {
        let harness = try Harness(tool: Tool.fails)
        harness.model.start()

        harness.model.capture(.screenshot)
        try await harness.waitUntilIdle()

        #expect(harness.model.notice == .problem("Capture failed. The system capture tool reported: could not create image from display"))
        #expect(harness.windowVisible)
    }

    @Test func aSecondCaptureRequestIsIgnoredWhileOneRuns() async throws {
        let harness = try Harness(tool: Tool.waits)
        harness.model.start()

        harness.model.capture(.screenshot)
        try await harness.waitUntil { harness.toolRan }
        harness.model.capture(.recording)
        #expect(harness.windowEvents == ["hide"], "the second request must not touch the window")

        harness.model.cancelCapture()
        try await harness.waitUntilIdle()
        #expect(!harness.model.isCapturing)
        #expect(harness.model.notice == .nothingSaved)
    }

    /// Quitting waits on this: the result of the cancelled capture is filed
    /// before the waiting action runs.
    @Test func whenIdleRunsAfterTheCancelledCaptureHasBeenFiled() async throws {
        let harness = try Harness(tool: Tool.writesMovieWhenTerminated)
        harness.model.start()
        harness.model.capture(.recording)
        try await harness.waitUntil { harness.toolRan }

        var itemsSeenByWaiter: [String]?
        harness.model.whenIdle { itemsSeenByWaiter = harness.model.items.map(\.kind.rawValue) }
        #expect(itemsSeenByWaiter == nil, "must not run while the capture is still going")

        harness.model.cancelCapture()
        try await harness.waitUntil { itemsSeenByWaiter != nil }

        #expect(itemsSeenByWaiter == ["video"], "the movie written on the way out must already be filed")
        #expect(!harness.model.isCapturing)
    }

    @Test func whenIdleRunsImmediatelyIfNothingIsCapturing() throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()
        var ran = false
        harness.model.whenIdle { ran = true }
        #expect(ran)
    }

    @Test func aDeletedCapturesFolderIsCreatedAgainAndStillWatched() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()
        try FileManager.default.removeItem(at: harness.captures.url)

        harness.model.reload()

        #expect(FileManager.default.fileExists(atPath: harness.captures.url.path))
        #expect(harness.model.notice == nil)
        try writeRealPNG(to: harness.captures.url.appendingPathComponent("after.png"), hue: 0.5)
        try await harness.waitUntil { !harness.model.items.isEmpty }
        #expect(harness.model.items.map(\.name) == ["after"], "the re-created folder must be watched")
    }

    @Test func anUnreadableCapturesFolderIsReportedNotShownAsEmpty() throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()
        // Replace the folder with a plain file so it can be neither read nor re-created.
        try FileManager.default.removeItem(at: harness.captures.url)
        try Data("x".utf8).write(to: harness.captures.url)
        defer { try? FileManager.default.removeItem(at: harness.captures.url) }

        harness.model.reload()

        guard case .problem(let message)? = harness.model.notice else {
            Issue.record("expected a problem notice, got \(String(describing: harness.model.notice))")
            return
        }
        #expect(message.contains(harness.captures.url.path))
        #expect(harness.model.items.isEmpty)
    }

    @Test func aFileAddedInFinderAppearsWithoutACapture() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()
        #expect(harness.model.items.isEmpty)

        try writeRealPNG(to: harness.captures.url.appendingPathComponent("dropped.png"), hue: 0.6)
        try await harness.waitUntil { !harness.model.items.isEmpty }

        #expect(harness.model.items.map(\.name) == ["dropped"])
    }

    @Test func trashingRemovesTheItemAndClearsTheSelection() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        try writeRealPNG(to: harness.captures.url.appendingPathComponent("one.png"), hue: 0.1)
        harness.model.start()
        let item = try #require(harness.model.items.first)
        harness.model.selection = item.id

        harness.model.trash(item)

        #expect(harness.model.items.isEmpty)
        #expect(harness.model.selection == nil)
        #expect(harness.model.selectedItem == nil)
        #expect(!FileManager.default.fileExists(atPath: item.url.path))
    }
}

@MainActor
@Suite struct CaptureActionsTests {
    @Test func copyPutsTheFileAndTheImageDataOnTheClipboard() throws {
        let folder = try TempFolder()
        let url = folder.url.appendingPathComponent("shot.png")
        try writeRealPNG(to: url, hue: 0.3)
        let item = CaptureItem(url: url, kind: .image, created: Date(), byteCount: 1)
        // A private pasteboard, so the test never touches the real clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quickshot-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        #expect(CaptureActions.copy(item, to: pasteboard))

        #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
        let png = try #require(pasteboard.data(forType: .png))
        #expect(png == (try Data(contentsOf: url)))
        #expect(NSImage(data: png)?.size == NSSize(width: 640, height: 400))
    }

    @Test func copyingARecordingPutsOnlyTheFileOnTheClipboard() throws {
        let folder = try TempFolder()
        let url = try folder.write(Fixture.mov, named: "clip.mov")
        let item = CaptureItem(url: url, kind: .video, created: Date(), byteCount: 1)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quickshot-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        #expect(CaptureActions.copy(item, to: pasteboard))

        #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
        #expect(pasteboard.data(forType: .png) == nil)
        #expect(pasteboard.data(forType: .tiff) == nil)
    }
}
