import Foundation
import Testing
@testable import QuickShotCore

@Suite struct CaptureCommandTests {
    let output = URL(fileURLWithPath: "/tmp/scratch/capture.png")

    @Test func screenshotOpensThePickerWithTheToolbarInSelectionMode() {
        #expect(CaptureCommand.arguments(for: .screenshot, output: output)
            == ["-i", "-U", "-J", "selection", "/tmp/scratch/capture.png"])
    }

    @Test func recordingOpensThePickerWithTheToolbarInVideoMode() {
        let movie = URL(fileURLWithPath: "/tmp/scratch/capture.mov")
        #expect(CaptureCommand.arguments(for: .recording, output: movie)
            == ["-i", "-U", "-J", "video", "/tmp/scratch/capture.mov"])
    }

    @Test func outputPathIsAlwaysTheLastArgument() {
        for mode in CaptureMode.allCases {
            #expect(CaptureCommand.arguments(for: mode, output: output).last == output.path)
        }
    }

    @Test func theSystemToolIsTheDefaultExecutable() {
        #expect(CaptureCommand.systemExecutable.path == "/usr/sbin/screencapture")
    }
}
