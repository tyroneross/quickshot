import Foundation
import QuickShotCore
import ScreenCaptureKit

/// Records one window or one app and nothing else, through ScreenCaptureKit.
/// The person picks the window or app in the system's own picker; other
/// windows are excluded even where they overlap, which the screen tool's
/// window mode does not promise.
///
/// Injectable: the model uses `AppRecording`, and tests stand in for it.
@MainActor
protocol AppRecording: AnyObject {
    /// Shows the picker, runs `beforeStart` (the countdown; `false` means
    /// cancelled), records until `stop()`, and reports like the tool.
    func record(to output: URL, preset: RecordingPreset, beforeStart: @MainActor () async -> Bool) async -> CaptureResult
    /// Ends the recording and keeps it.
    func stop()
    /// Ends the recording, or the picker, and keeps nothing.
    func cancel()
}

@MainActor
final class WindowRecorder: NSObject, AppRecording {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var finish: CheckedContinuation<CaptureResult, Never>?
    private var pickerWaiter: CheckedContinuation<SCContentFilter?, Never>?
    private var stopRequested = false
    private var cancelRequested = false
    private var output: URL?

    func record(to output: URL, preset: RecordingPreset, beforeStart: @MainActor () async -> Bool) async -> CaptureResult {
        self.output = output
        stopRequested = false
        cancelRequested = false
        guard let filter = await pick() else { return .cancelled }
        guard await beforeStart(), !cancelRequested, !stopRequested else { return .cancelled }
        let configuration = SCStreamConfiguration()
        let scale = filter.pointPixelScale
        configuration.width = Int(filter.contentRect.width * CGFloat(scale))
        configuration.height = Int(filter.contentRect.height * CGFloat(scale))
        configuration.showsCursor = true
        configuration.capturesAudio = preset == .demo
        configuration.captureMicrophone = preset == .demo
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = output
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .hevc
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        do {
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()
        } catch {
            return .failed("Could not start recording the window: \(error.localizedDescription)")
        }
        self.stream = stream
        self.recordingOutput = recordingOutput
        if stopRequested || cancelRequested { await endCapture() }
        let result = await withCheckedContinuation { finish = $0 }
        self.stream = nil
        self.recordingOutput = nil
        return result
    }

    func stop() {
        stopRequested = true
        guard stream != nil else { return }
        Task { await endCapture() }
    }

    func cancel() {
        cancelRequested = true
        pickerWaiter?.resume(returning: nil)
        pickerWaiter = nil
        guard stream != nil else { return }
        Task { await endCapture() }
    }

    private func endCapture() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        // The recording output reports when the file is complete; a cancel
        // does not wait for it, since nothing is kept.
        if cancelRequested { settle(.cancelled) }
    }

    private func settle(_ result: CaptureResult) {
        if case .cancelled = result, let output { try? FileManager.default.removeItem(at: output) }
        finish?.resume(returning: result)
        finish = nil
    }

    // MARK: Picker

    private func pick() async -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleApplication]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
        let filter = await withCheckedContinuation { pickerWaiter = $0 }
        picker.isActive = false
        picker.remove(self)
        return filter
    }
}

extension WindowRecorder: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // SCContentFilter is an immutable description the system hands over;
        // it is only read on the main actor after this.
        let chosen = UncheckedSendable(filter)
        Task { @MainActor in
            pickerWaiter?.resume(returning: chosen.value)
            pickerWaiter = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            pickerWaiter?.resume(returning: nil)
            pickerWaiter = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            pickerWaiter?.resume(returning: nil)
            pickerWaiter = nil
        }
    }
}

extension WindowRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            // The window closed, or the system ended the stream: keep what was
            // written so far, which the recording output finishes.
            if !cancelRequested, recordingOutput != nil { stopRequested = true }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard !cancelRequested else { return }
            if let output, FileManager.default.fileExists(atPath: output.path) {
                settle(.captured([output]))
            } else {
                settle(.failed("The window recording was not written."))
            }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            guard !cancelRequested else { return }
            settle(.failed("Recording the window failed: \(error.localizedDescription)"))
        }
    }
}

/// Carries a value the compiler cannot prove Sendable across an actor hop.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
