import AppKit
import ClipboardCore
import QuickShotCore

/// What the person can do with one capture.
@MainActor
enum CaptureActions {
    /// Puts the capture on the clipboard as a file, plus image data for
    /// screenshots so it pastes into editors and chat boxes alike.
    @discardableResult
    ///
    /// Everything is prepared first; the clipboard is left untouched when the
    /// file has gone or cannot be read.
    static func copy(_ item: CaptureItem, to pasteboard: NSPasteboard = .general) -> Bool {
        guard FileManager.default.isReadableFile(atPath: item.url.path) else { return false }
        let entry = NSPasteboardItem()
        entry.setString(item.url.absoluteString, forType: .fileURL)
        if item.kind == .image {
            guard let data = try? Data(contentsOf: item.url) else { return false }
            if item.url.pathExtension.lowercased() == "png" {
                entry.setData(data, forType: .png)
            } else if let tiff = NSImage(data: data)?.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
        }
        return write(entry, to: pasteboard)
    }

    /// Puts PNG bytes on the clipboard, with the file they were saved to when
    /// there is one. Used by the editor, whose picture may exist only in memory
    /// when the save failed.
    @discardableResult
    static func copyPNG(_ data: Data, file: URL?, to pasteboard: NSPasteboard = .general) -> Bool {
        let entry = NSPasteboardItem()
        if let file { entry.setString(file.absoluteString, forType: .fileURL) }
        entry.setData(data, forType: .png)
        return write(entry, to: pasteboard)
    }

    private static func write(_ entry: NSPasteboardItem, to pasteboard: NSPasteboard) -> Bool {
        // Marked as QuickShot's own write, so the clipboard history does not
        // record a capture that is already listed under Screenshots.
        entry.setData(Data(), forType: ClipboardReader.ownWriteType)
        pasteboard.clearContents()
        return pasteboard.writeObjects([entry])
    }

    /// Opens a screenshot in Preview, where Markup annotates it, or a
    /// recording in QuickTime Player, which trims it.
    static func open(_ item: CaptureItem) {
        let bundleID = item.kind == .image ? "com.apple.Preview" : "com.apple.QuickTimePlayerX"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(item.url)
            return
        }
        NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    static func openFolder(_ directory: URL) {
        NSWorkspace.shared.open(directory)
    }

    /// Opens the Privacy & Security pane, where "Paste from Other Apps" lives.
    static func openPasteboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts a fresh copy of the app. macOS only applies a new Screen
    /// Recording grant to a newly started app. Reports whether the new copy
    /// started; the caller quits this one only then.
    static func launchNewInstance(completion: @escaping @MainActor (_ error: String?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let failure = app == nil ? (error?.localizedDescription ?? "The app could not be started again.") : nil
            Task { @MainActor in completion(failure) }
        }
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
