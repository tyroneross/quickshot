import Foundation

/// What the person asked to capture.
public enum CaptureMode: String, Sendable, CaseIterable {
    case screenshot
    case recording
}

/// Builds the command line for the system capture tool.
///
/// Neither mode uses the tool's `-U` toolbar. Measured on macOS 27.0.1: with
/// the toolbar the system saves to its own "Save to" location (the Desktop by
/// default) and ignores the file path it was given, so the capture never
/// reaches the captures folder.
public enum CaptureCommand {
    public static let systemExecutable = URL(fileURLWithPath: "/usr/sbin/screencapture")

    public static func arguments(for mode: CaptureMode, output: URL) -> [String] {
        switch mode {
        case .screenshot:
            // The system crosshair: drag an area, or press Space for a window.
            ["-i", output.path]
        case .recording:
            // Records the main display until the tool is interrupted.
            ["-v", output.path]
        }
    }

    /// The file name requested from the tool. The filer re-types the result by
    /// content, so the extension here is a hint and never trusted.
    public static func requestedFileName(for mode: CaptureMode) -> String {
        switch mode {
        case .screenshot: "capture.png"
        case .recording: "capture.mov"
        }
    }
}
