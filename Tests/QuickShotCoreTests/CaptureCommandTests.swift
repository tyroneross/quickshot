import Foundation
import Testing
import TestSupport
@testable import QuickShotCore

@Suite struct CaptureCommandTests {
    let output = URL(fileURLWithPath: "/tmp/scratch/capture.png")

    @Test func anAreaCaptureOpensTheSystemCrosshairAndNamesTheFile() {
        #expect(CaptureCommand.arguments(for: .area, output: output) == ["-i", "/tmp/scratch/capture.png"])
    }

    /// No picker and no flags: the tool captures every screen at once.
    @Test func aFullScreenCaptureTakesEveryScreenAtOnce() {
        #expect(CaptureCommand.arguments(for: .fullScreen, output: output) == ["/tmp/scratch/capture.png"])
    }

    @Test func aQuickRecordingShowsClicksAndRecordsNoAudio() {
        let movie = URL(fileURLWithPath: "/tmp/scratch/capture.mov")
        #expect(CaptureCommand.arguments(for: .recording, preset: .quick, output: movie) == ["-v", "-k", "/tmp/scratch/capture.mov"])
    }

    @Test func aDemoRecordingAddsMicrophoneAndSystemAudio() {
        let movie = URL(fileURLWithPath: "/tmp/scratch/capture.mov")
        #expect(CaptureCommand.arguments(for: .recording, preset: .demo, output: movie) == ["-v", "-k", "-g", "-A", "/tmp/scratch/capture.mov"])
    }

    @Test func onlyRecordingsUseTheVideoFlagAndOnlyTheAreaUsesThePicker() {
        for preset in RecordingPreset.allCases {
            for mode in CaptureMode.allCases {
                let arguments = CaptureCommand.arguments(for: mode, preset: preset, output: output)
                #expect(arguments.contains("-v") == (mode == .recording), "\(mode) \(preset)")
                #expect(arguments.contains("-i") == (mode == .area), "\(mode) \(preset)")
            }
        }
    }

    @Test func eachPresetSaysWhatItDoes() {
        for preset in RecordingPreset.allCases {
            #expect(!preset.meaning.isEmpty)
        }
        #expect(RecordingPreset.quick.meaning != RecordingPreset.demo.meaning)
    }

    /// Regression, 2026-11-09: with the toolbar flag the system saved two
    /// captures to the Desktop and ignored the path, so QuickShot reported
    /// "Nothing was saved". Flags that make the tool ignore the file argument
    /// must never come back (`-U` toolbar, `-u` and `-p` per the usage text,
    /// `-c` clipboard).
    @Test func noModeUsesAFlagThatIgnoresTheFilePath() {
        for mode in CaptureMode.allCases {
            for preset in RecordingPreset.allCases {
                let arguments = CaptureCommand.arguments(for: mode, preset: preset, output: output)
                for forbidden in ["-U", "-u", "-p", "-c"] {
                    #expect(!arguments.contains(forbidden), "\(mode) \(preset) passes \(forbidden)")
                }
                #expect(arguments.last == output.path, "the file path must be the last argument")
            }
        }
    }

    @Test func theSystemToolIsTheDefaultExecutable() {
        #expect(CaptureCommand.systemExecutable.path == "/usr/sbin/screencapture")
    }
}
