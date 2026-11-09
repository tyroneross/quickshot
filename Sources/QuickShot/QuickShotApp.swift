import AppKit
import Carbon.HIToolbox
import QuickShotCore
import SwiftUI

@main
struct QuickShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(delegate.model)
        } label: {
            MenuBarLabel().environment(delegate.model)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: model.isCapturing ? "record.circle.fill" : "camera.viewfinder")
            .accessibilityLabel(model.isCapturing ? "QuickShot, capturing" : "QuickShot")
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isCapturing {
            Button("Cancel Capture") { model.cancelCapture() }
        } else {
            Button("Take Screenshot") { model.capture(.screenshot) }
                .keyboardShortcut("s", modifiers: [.control, .shift])
            Button("Record Screen") { model.capture(.recording) }
                .keyboardShortcut("r", modifiers: [.control, .shift])
        }
        Divider()
        Button("Show Library") { model.showLibrary() }
        Button("Open Captures Folder") { CaptureActions.openFolder(model.library.directory) }
        Divider()
        Button("Quit QuickShot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let hotKeys = HotKeyCenter()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.showLibrary = { [weak self] in self?.showLibrary() }
        model.hideLibrary = { [weak self] in self?.window?.orderOut(nil) }
        model.isLibraryVisible = { [weak self] in self?.window?.isVisible ?? false }
        model.start()
        registerHotKeys()
        showLibrary()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAccess()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showLibrary()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isCapturing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A capture is in progress"
        alert.informativeText = "Quitting now closes the system picker. An unfinished capture is not saved to QuickShot."
        alert.addButton(withTitle: "Keep Capturing")
        alert.addButton(withTitle: "Quit Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.cancelCapture()
        return .terminateNow
    }

    private func registerHotKeys() {
        let modifiers = controlKey | shiftKey
        let screenshot = hotKeys.register(keyCode: kVK_ANSI_S, modifiers: modifiers) { [weak self] in
            self?.model.capture(.screenshot)
        }
        let recording = hotKeys.register(keyCode: kVK_ANSI_R, modifiers: modifiers) { [weak self] in
            self?.model.capture(.recording)
        }
        let unavailable = [
            screenshot ? nil : Copy.screenshotShortcut,
            recording ? nil : Copy.recordShortcut,
        ].compactMap { $0 }
        if !unavailable.isEmpty, model.notice == nil {
            model.notice = .problem("Another app already uses \(unavailable.joined(separator: " and ")). The buttons and the menu bar item still work.")
        }
    }

    private func showLibrary() {
        if window == nil { window = LibraryWindow.make(model: model) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Builds the one library window.
@MainActor
enum LibraryWindow {
    static let minimumContentSize = NSSize(width: 480, height: 360)
    static let defaultContentSize = NSSize(width: 860, height: 560)

    static func make(model: AppModel) -> NSWindow {
        let hosting = NSHostingController(rootView: LibraryView().environment(model))
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuickShot"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumContentSize
        window.setContentSize(defaultContentSize)
        window.center()
        window.setFrameAutosaveName("QuickShotLibrary")
        return window
    }
}
