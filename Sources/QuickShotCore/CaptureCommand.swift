import Foundation

/// What the person asked to capture. The system toolbar lets them switch
/// between the two after it opens, so this is only the starting mode.
public enum CaptureMode: String, Sendable, CaseIterable {
    case screenshot
    case recording
}

/// Builds the command line for the system capture tool.
///
/// `-i` opens the interactive picker, `-U` adds the system toolbar (the
/// Cmd+Shift+5 interface) and `-J` sets the mode the toolbar starts in.
public enum CaptureCommand {
    public static let systemExecutable = URL(fileURLWithPath: "/usr/sbin/screencapture")

    public static func arguments(for mode: CaptureMode, output: URL) -> [String] {
        ["-i", "-U", "-J", startingStyle(for: mode), output.path]
    }

    /// The file name requested from the tool. The filer re-types the result by
    /// content, so the extension here is a hint and never trusted.
    public static func requestedFileName(for mode: CaptureMode) -> String {
        switch mode {
        case .screenshot: "capture.png"
        case .recording: "capture.mov"
        }
    }

    static func startingStyle(for mode: CaptureMode) -> String {
        switch mode {
        case .screenshot: "selection"
        case .recording: "video"
        }
    }
}
