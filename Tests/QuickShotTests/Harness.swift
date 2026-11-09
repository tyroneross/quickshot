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
    private(set) var windowVisible: Bool
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
            screenAccess: access.screenAccess
        )
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
