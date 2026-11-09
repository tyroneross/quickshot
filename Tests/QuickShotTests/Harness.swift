import AppKit
import Foundation
import QuickShotCore
import TestSupport
@testable import QuickShot

/// Screen-access answers a test can change while the model runs.
final class AccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    private var requestCount = 0

    init(granted: Bool) { self.granted = granted }

    var requests: Int { lock.withLock { requestCount } }
    func setGranted(_ value: Bool) { lock.withLock { granted = value } }

    var screenAccess: ScreenAccess {
        ScreenAccess(
            isGranted: { self.lock.withLock { self.granted } },
            request: { self.lock.withLock { self.requestCount += 1 } }
        )
    }
}

/// A model wired to a stand-in capture tool, a scratch captures folder and a
/// recorded window, so the real model logic runs end to end.
@MainActor
final class Harness {
    let scratch: TempFolder
    let captures: TempFolder
    let access: AccessBox
    let model: AppModel
    let appRecorder = FakeAppRecorder()
    private(set) var windowVisible: Bool
    private(set) var flashes = 0
    private(set) var copied: [CaptureItem] = []
    private(set) var windowEvents: [String] = []

    /// - Parameter tool: shell body for the stand-in tool; `$OUT` is the
    ///   output path the model asked for.
    init(tool: String, granted: Bool = true, windowVisible: Bool = true) throws {
        scratch = try TempFolder()
        captures = try TempFolder()
        access = AccessBox(granted: granted)
        self.windowVisible = windowVisible
        let executable = try scratch.script(tool)
        model = AppModel(
            library: CaptureLibrary(directory: captures.url, remove: { try FileManager.default.removeItem(at: $0) }),
            runner: CaptureRunner(executable: executable, scratchRoot: scratch.url),
            screenAccess: access.screenAccess,
            defaults: UserDefaults(suiteName: "QuickShotTests.\(UUID().uuidString)")!
        )
        model.flash = { [unowned self] in flashes += 1 }
        model.copyToClipboard = { [unowned self] item in copied.append(item); return true }
        model.shrinkImage = { $0 }
        model.countdownTick = .milliseconds(20)
        model.countsDown = false
        model.appRecorder = appRecorder
        // The shrink step stands in for the real export: a copy of the movie
        // with the name the real step would give it.
        model.shrink = { source in
            let small = source.deletingPathExtension().appendingPathExtension("1080p").appendingPathExtension("mp4")
            try FileManager.default.copyItem(at: source, to: small)
            return small
        }
        model.showLibrary = { [unowned self] in self.windowVisible = true; self.windowEvents.append("show") }
        model.hideLibrary = { [unowned self] in self.windowVisible = false; self.windowEvents.append("hide") }
        model.isLibraryVisible = { [unowned self] in self.windowVisible }
    }

    var toolRan: Bool {
        FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("ran").path)
    }

    func waitUntilIdle() async throws {
        for _ in 0..<400 where model.isCapturing {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

enum Tool {
    static let mark = ": > \"$(dirname \"$0\")/ran\""
    static let writesPNG = "\(mark); \(Fixture.pngPrintf) > \"$OUT\""
    static let cancels = "\(mark); exit 1"
    static let fails = "\(mark); echo 'could not create image from display' >&2; exit 1"
    static let waits = "\(mark); while :; do sleep 0.05; done"
    /// The real recorder: runs until interrupted, then writes the movie.
    static let recordsUntilInterrupted = "trap 'printf \"\\000\\000\\000\\024ftypqt  0000\" > \"$OUT\"; exit 0' INT; \(mark); while :; do sleep 0.05; done"
    /// Like a recording: runs until terminated, then writes a movie.
    static let writesMovieWhenTerminated = "trap 'printf \"\\000\\000\\000\\024ftypqt  0000\" > \"$OUT\"; exit 0' TERM; \(mark); while :; do sleep 0.05; done"
}

/// Draws a real PNG so thumbnails and the clipboard handle true image data.
func writeRealPNG(to url: URL, width: Int = 640, height: Int = 400, hue: CGFloat) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(hue: hue, saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(hue: hue, saturation: 0.7, brightness: 0.6, alpha: 1).setFill()
    NSRect(x: 40, y: height - 90, width: width - 80, height: 50).fill()
    for row in 0..<4 {
        NSColor(white: 0.25, alpha: 1).setFill()
        NSRect(x: 40, y: height - 150 - row * 50, width: width - 200 - row * 60, height: 18).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Stands in for the window recorder: "picks" at once, records until stop,
/// then writes a movie, unless cancelled.
@MainActor
final class FakeAppRecorder: AppRecording {
    private(set) var started = 0
    private(set) var countedDown = false
    private var stopped = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func record(to output: URL, preset: RecordingPreset, beforeStart: @MainActor () async -> Bool) async -> CaptureResult {
        stopped = false
        cancelled = false
        let go = await beforeStart()
        countedDown = true
        guard go, !cancelled else { return .cancelled }
        started += 1
        if !stopped { await withCheckedContinuation { waiter = $0 } }
        if cancelled { return .cancelled }
        try? Data(Fixture.mov).write(to: output)
        return .captured([output])
    }

    func stop() { stopped = true; waiter?.resume(); waiter = nil }
    func cancel() { cancelled = true; waiter?.resume(); waiter = nil }
}
