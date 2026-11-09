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
    /// True once frames are being written; before that, Stop means Cancel.
    var isRecording: Bool { get }
    /// Shows the picker, runs `beforeStart` (the countdown; `false` means
    /// cancelled), records until `stop()`, and reports like the tool.
    func record(to output: URL, preset: RecordingPreset, beforeStart: @MainActor () async -> Bool) async -> CaptureResult
    /// Ends the recording and keeps it. Before recording has started it
    /// cancels instead, since there is nothing to keep.
    func stop()
    /// Ends the recording, or the picker, and keeps nothing.
    func cancel()
}

@MainActor
final class WindowRecorder: NSObject, AppRecording {
    /// One recording from picker to file. Callbacks name the session they
    /// belong to, so a late callback from an old one cannot touch a new one.
    private final class Session {
        let output: URL
        var stream: SCStream?
        var recordingOutput: SCRecordingOutput?
        var isRecording = false
        var cancelled = false
        /// The result, once known. Set exactly once; read when awaited.
        var result: CaptureResult?
        var waiter: CheckedContinuation<CaptureResult, Never>?
        var pickerWaiter: CheckedContinuation<UncheckedSendable<SCContentFilter>?, Never>?
        init(output: URL) { self.output = output }
    }

    private var session: Session?
    var isRecording: Bool { session?.isRecording ?? false }

    func record(to output: URL, preset: RecordingPreset, beforeStart: @MainActor () async -> Bool) async -> CaptureResult {
        let session = Session(output: output)
        self.session = session
        defer { if self.session === session { self.session = nil } }

        guard let filter = await pick(session) else { return .cancelled }
        guard await beforeStart(), !session.cancelled else { return .cancelled }

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
        session.stream = stream
        session.recordingOutput = recordingOutput
        do {
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()
        } catch {
            settle(session, .failed("Could not start recording the window: \(error.localizedDescription)"))
            return await outcome(of: session)
        }
        if session.result != nil {
            // The output failed while the stream was starting: the stream is
            // up now, so take it down before reporting.
            try? await stream.stopCapture()
            return await outcome(of: session)
        }
        session.isRecording = true
        // A cancel that arrived while starting is honoured now.
        if session.cancelled { await end(session, keep: false) }
        return await outcome(of: session)
    }

    func stop() {
        guard let session else { return }
        guard session.isRecording else { cancel(); return }
        Task { await end(session, keep: true) }
    }

    func cancel() {
        guard let session else { return }
        // After Stop the file is being finished for keeping; a cancel now
        // would throw away what the person asked to keep.
        guard session.result == nil, session.isRecording || session.stream == nil else { return }
        session.cancelled = true
        session.pickerWaiter?.resume(returning: nil)
        session.pickerWaiter = nil
        if session.isRecording { Task { await end(session, keep: false) } }
    }

    // MARK: One way out

    /// Stops the stream. Kept recordings are settled by the recording
    /// output once the file is complete; everything else settles here.
    private func end(_ session: Session, keep: Bool) async {
        guard session.result == nil, let stream = session.stream, session.isRecording else { return }
        session.isRecording = false
        do {
            try await stream.stopCapture()
        } catch {
            settle(session, .failed("Could not stop recording the window: \(error.localizedDescription)"))
            return
        }
        if !keep { settle(session, .cancelled) }
    }

    private func settle(_ session: Session, _ result: CaptureResult) {
        guard session.result == nil else { return }
        // A partial file is of no use to anyone: a failed or cancelled
        // recording leaves nothing behind.
        if case .captured = result {} else { try? FileManager.default.removeItem(at: session.output) }
        session.result = result
        session.waiter?.resume(returning: result)
        session.waiter = nil
    }

    /// The result, now if already known, otherwise when it arrives.
    private func outcome(of session: Session) async -> CaptureResult {
        if let result = session.result { return result }
        let result = await withCheckedContinuation { session.waiter = $0 }
        session.stream = nil
        session.recordingOutput = nil
        return result
    }

    // MARK: Picker

    private func pick(_ session: Session) async -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleApplication]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        // One observer per session: a late callback from an earlier picker
        // finds its own session closed and does nothing.
        let observer = PickerObserver(session: session)
        picker.add(observer)
        picker.isActive = true
        picker.present()
        let filter: UncheckedSendable<SCContentFilter>? = session.cancelled ? nil : await withCheckedContinuation { session.pickerWaiter = $0 }
        observer.closed = true
        picker.isActive = false
        picker.remove(observer)
        return filter?.value
    }

    /// Hands the picker's answer to the one session it was opened for.
    @MainActor
    private final class PickerObserver: NSObject, SCContentSharingPickerObserver {
        private let session: Session
        /// Set on the main actor once the session has its answer.
        var closed = false
        init(session: Session) { self.session = session }

        private func finish(with filter: UncheckedSendable<SCContentFilter>?) {
            guard !closed else { return }
            closed = true
            session.pickerWaiter?.resume(returning: filter)
            session.pickerWaiter = nil
        }

        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
            // SCContentFilter is an immutable description the system hands
            // over; it is only read on the main actor after this.
            let chosen = UncheckedSendable(filter)
            Task { @MainActor [weak self] in self?.finish(with: chosen) }
        }

        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
            Task { @MainActor [weak self] in self?.finish(with: nil) }
        }

        nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
            Task { @MainActor [weak self] in self?.finish(with: nil) }
        }
    }
}

extension WindowRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let which = UncheckedSendable(stream)
        Task { @MainActor in
            // The window closed, or the system ended the stream. The stream is
            // already stopped; keep what was written, which the recording
            // output finishes and reports.
            guard let session, session.stream === which.value, session.result == nil else { return }
            session.isRecording = false
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let which = UncheckedSendable(recordingOutput)
        Task { @MainActor in
            guard let session, session.recordingOutput === which.value, session.result == nil else { return }
            if session.cancelled {
                settle(session, .cancelled)
            } else if FileManager.default.fileExists(atPath: session.output.path) {
                settle(session, .captured([session.output]))
            } else {
                settle(session, .failed("The window recording was not written."))
            }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let which = UncheckedSendable(recordingOutput)
        let message = error.localizedDescription
        Task { @MainActor in
            guard let session, session.recordingOutput === which.value, session.result == nil else { return }
            // The stream may still be running: stop it, then report.
            if session.isRecording, let stream = session.stream {
                session.isRecording = false
                try? await stream.stopCapture()
            }
            settle(session, .failed("Recording the window failed: \(message)"))
        }
    }
}

/// Carries a value the compiler cannot prove Sendable across an actor hop.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
