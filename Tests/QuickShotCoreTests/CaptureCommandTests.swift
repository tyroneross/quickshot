import Foundation
import Testing
import TestSupport
@testable import QuickShotCore

@Suite struct CaptureCommandTests {
    let output = URL(fileURLWithPath: "/tmp/scratch/capture.png")

    @Test func aScreenshotOpensTheSystemCrosshairAndNamesTheFile() {
        #expect(CaptureCommand.arguments(for: .screenshot, output: output) == ["-i", "/tmp/scratch/capture.png"])
    }

    @Test func aRecordingStartsAtOnceAndNamesTheFile() {
        let movie = URL(fileURLWithPath: "/tmp/scratch/capture.mov")
        #expect(CaptureCommand.arguments(for: .recording, output: movie) == ["-v", "/tmp/scratch/capture.mov"])
    }

    /// Regression, 2026-11-09: with the toolbar flag the system saved two
    /// captures to the Desktop and ignored the path, so QuickShot reported
    /// "Nothing was saved". Flags that make the tool ignore the file argument
    /// must never come back (`-U` toolbar, `-u` and `-p` per the usage text,
    /// `-c` clipboard).
    @Test func noModeUsesAFlagThatIgnoresTheFilePath() {
        for mode in CaptureMode.allCases {
            let arguments = CaptureCommand.arguments(for: mode, output: output)
            for forbidden in ["-U", "-u", "-p", "-c"] {
                #expect(!arguments.contains(forbidden), "\(mode) passes \(forbidden)")
            }
            #expect(arguments.last == output.path, "the file path must be the last argument")
        }
    }

    @Test func theSystemToolIsTheDefaultExecutable() {
        #expect(CaptureCommand.systemExecutable.path == "/usr/sbin/screencapture")
    }
}
