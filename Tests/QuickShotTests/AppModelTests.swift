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
        #expect(!harness.model.askedForAccess, "the first step shown is turning it on")

        harness.model.capture(.screenshot)
        try await Task.sleep(for: .milliseconds(200))

        #expect(!harness.model.isCapturing)
        #expect(!harness.toolRan, "the tool must not run without access")
        #expect(harness.access.requests == 1)
        #expect(harness.model.askedForAccess, "after asking, the step shown is reopening the app")
        #expect(harness.model.notice == .permissionNeeded)
        #expect(harness.model.items.isEmpty)
        #expect(harness.windowEvents == ["show"])
    }

    /// Reopen starts a new copy first and quits this one only when that worked.
    @Test func reopenQuitsOnlyAfterTheNewCopyStartsAndIgnoresASecondClick() throws {
        let harness = try Harness(tool: Tool.writesPNG, granted: false)
        var launches: [@MainActor (String?) -> Void] = []
        var quits = 0
        harness.model.launchNewInstance = { launches.append($0) }
        harness.model.quit = { quits += 1 }

        harness.model.reopen()
        harness.model.reopen() // a second click while the first is still starting
        #expect(launches.count == 1, "a second click started a second copy")
        #expect(quits == 0, "this copy quit before the new one was running")

        launches[0](nil)
        #expect(quits == 1)
    }

    @Test func aFailedReopenKeepsTheAppRunningAndSaysWhy() throws {
        let harness = try Harness(tool: Tool.writesPNG, granted: false)
        var quits = 0
        harness.model.launchNewInstance = { $0("The application cannot be opened.") }
        harness.model.quit = { quits += 1 }

        harness.model.reopen()

        #expect(quits == 0, "the only running copy quit after a failed relaunch")
        #expect(!harness.model.isReopening, "a retry must be possible")
        guard case .problem(let message)? = harness.model.notice else {
            Issue.record("expected a problem notice")
            return
        }
        #expect(message.contains("The application cannot be opened."))
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

    @Test func stoppingARecordingFilesTheMovieAndSelectsIt() async throws {
        let harness = try Harness(tool: Tool.recordsUntilInterrupted)
        harness.model.start()

        harness.model.capture(.recording)
        try await harness.waitUntil { harness.toolRan }
        #expect(harness.model.activeCapture == .recording)
        #expect(!harness.windowVisible, "the window must stay out of the recording")

        harness.model.stopRecording()
        try await harness.waitUntilIdle()

        let item = try #require(harness.model.items.first)
        #expect(item.kind == .video)
        #expect(item.url.lastPathComponent.hasPrefix("Recording "))
        #expect(harness.model.selection == item.id)
        #expect(harness.model.notice == nil)
        #expect(harness.windowVisible)
    }

    /// Stop pressed in the same instant as Record (a double press of the
    /// shortcut, or quitting at once): the request must not be lost.
    @Test func stoppingBeforeTheRecorderHasStartedLeavesNothingRunning() async throws {
        let harness = try Harness(tool: Tool.recordsUntilInterrupted)
        harness.model.start()

        harness.model.capture(.recording)
        harness.model.stopRecording()
        try await harness.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))

        #expect(harness.model.activeCapture == nil, "the recording kept going after Stop")
        #expect(!harness.toolRan, "the recorder was started after it had been stopped")
        #expect(harness.model.items.isEmpty)
    }

    /// The record shortcut is one key for both: start, then stop.
    @Test func toggleRecordingStartsThenStops() async throws {
        let harness = try Harness(tool: Tool.recordsUntilInterrupted)
        harness.model.start()

        harness.model.toggleRecording()
        try await harness.waitUntil { harness.toolRan }
        #expect(harness.model.activeCapture == .recording)

        harness.model.toggleRecording()
        try await harness.waitUntilIdle()
        #expect(harness.model.items.map(\.kind) == [.video])
    }

    @Test func stopRecordingDoesNothingWhileAScreenshotIsBeingChosen() async throws {
        let harness = try Harness(tool: Tool.recordsUntilInterrupted)
        harness.model.start()
        harness.model.capture(.screenshot)
        try await harness.waitUntil { harness.toolRan }

        harness.model.stopRecording()
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.model.activeCapture == .screenshot, "the screenshot picker must not be interrupted by Stop Recording")

        harness.model.cancelCapture()
        try await harness.waitUntilIdle()
        #expect(harness.model.items.isEmpty)
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

    /// Cancel pressed in the same instant as the capture request: the tool
    /// must never start.
    @Test func cancellingImmediatelyAfterRequestingNeverStartsTheTool() async throws {
        let harness = try Harness(tool: Tool.waits)
        harness.model.start()

        harness.model.capture(.screenshot)
        harness.model.cancelCapture()
        try await harness.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))

        #expect(!harness.toolRan, "the picker was opened after it had been cancelled")
        #expect(!harness.model.isCapturing)
        #expect(harness.model.notice == .nothingSaved)
    }

    /// The folder is moved away and a new one appears at the same path: the
    /// model must watch the new one.
    @Test func aReplacedCapturesFolderIsWatchedAgain() async throws {
        let harness = try Harness(tool: Tool.writesPNG)
        harness.model.start()
        let original = harness.captures.url
        let aside = original.deletingLastPathComponent().appendingPathComponent("aside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: aside) }

        try FileManager.default.moveItem(at: original, to: aside)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(800)) // let the folder-gone event arrive

        try writeRealPNG(to: original.appendingPathComponent("in-new-folder.png"), hue: 0.2)
        try await harness.waitUntil { !harness.model.items.isEmpty }

        #expect(harness.model.items.map(\.name) == ["in-new-folder"])
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

    /// The file was removed in Finder before the list refreshed.
    @Test func copyingAMissingFileFailsAndLeavesTheClipboardAlone() throws {
        let folder = try TempFolder()
        let gone = folder.url.appendingPathComponent("gone.png")
        let item = CaptureItem(url: gone, kind: .image, created: Date(), byteCount: 1)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quickshot-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what was there before", forType: .string)

        #expect(!CaptureActions.copy(item, to: pasteboard))

        #expect(pasteboard.string(forType: .string) == "what was there before")
        #expect(pasteboard.string(forType: .fileURL) == nil)
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
