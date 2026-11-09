import Foundation

/// What the person asked to capture.
public enum CaptureMode: String, Sendable, CaseIterable {
    /// Every screen, at once, with no picker.
    case fullScreen
    /// The system crosshair: drag over an area, or press Space for a window.
    case area
    /// The main display, until stopped.
    case recording
}

/// How a recording is made. The system tool always records at the display's
/// native resolution; the presets differ in what is recorded alongside and
/// in whether the movie is shrunk afterwards.
public enum RecordingPreset: String, Sendable, CaseIterable {
    /// For a bug report or something to send to an AI: mouse clicks shown, no
    /// audio, and the movie is shrunk to 1080p HEVC once it is saved.
    case quick
    /// For a demo: mouse clicks shown, microphone and system audio, kept at
    /// full resolution.
    case demo

    /// Shown next to the switch, so the choice explains itself.
    public var meaning: String {
        switch self {
        case .quick: "Small 1080p file, clicks shown, no audio."
        case .demo: "Native resolution with microphone and system audio."
        }
    }

    /// A menu item that says what changes, since a menu has no room for
    /// the meaning beside it.
    public var menuTitle: String {
        switch self {
        case .quick: "Quick: 1080p, no audio"
        case .demo: "Demo: native resolution, microphone and system audio"
        }
    }
}

/// Builds the command line for the system capture tool.
///
/// No mode uses the tool's `-U` toolbar. Measured on macOS 27.0.1: with the
/// toolbar the system saves to its own "Save to" location (the Desktop by
/// default) and ignores the file path it was given, so the capture never
/// reaches the captures folder.
public enum CaptureCommand {
    public static let systemExecutable = URL(fileURLWithPath: "/usr/sbin/screencapture")

    public static func arguments(for mode: CaptureMode, preset: RecordingPreset = .quick, output: URL) -> [String] {
        switch mode {
        case .fullScreen:
            // No flags: the tool writes one file per screen, named from this
            // path, and exits at once.
            [output.path]
        case .area:
            ["-i", output.path]
        case .recording:
            // -k draws mouse clicks. -g adds the microphone, -A the system audio.
            switch preset {
            case .quick: ["-v", "-k", output.path]
            case .demo: ["-v", "-k", "-g", "-A", output.path]
            }
        }
    }

    /// The file name requested from the tool. The filer re-types the result by
    /// content, so the extension here is a hint and never trusted.
    public static func requestedFileName(for mode: CaptureMode) -> String {
        switch mode {
        case .fullScreen, .area: "capture.png"
        case .recording: "capture.mov"
        }
    }
}
