import AppKit
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
        Image(systemName: model.activeCapture == .recording ? "record.circle.fill" : "camera")
            .accessibilityLabel(model.activeCapture == .recording ? "QuickShot, recording" : "QuickShot")
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.activeCapture {
        case .recording:
            Button("Stop Recording") { model.stopRecording() }
                .keyboardShortcut(Shortcut.recording.keyboardShortcut)
        case .screenshot:
            Button("Cancel Screenshot") { model.cancelCapture() }
        case nil:
            Button("Take Screenshot") { model.capture(.screenshot) }
                .keyboardShortcut(Shortcut.screenshot.keyboardShortcut)
            Button("Record Screen") { model.capture(.recording) }
                .keyboardShortcut(Shortcut.recording.keyboardShortcut)
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
        guard let active = model.activeCapture else { return .terminateNow }
        let alert = NSAlert()
        switch active {
        case .recording:
            alert.messageText = "A recording is in progress"
            alert.informativeText = "Quitting stops the recording and saves it to QuickShot."
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Stop, Save and Quit")
        case .screenshot:
            alert.messageText = "A screenshot is in progress"
            alert.informativeText = "Quitting closes the screenshot picker without saving."
            alert.addButton(withTitle: "Keep Going")
            alert.addButton(withTitle: "Quit Anyway")
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // Wait for the tool to exit so its result is filed before the app goes.
        switch active {
        case .recording: model.stopRecording()
        case .screenshot: model.cancelCapture()
        }
        model.whenIdle { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func registerHotKeys() {
        // The record shortcut starts a recording and, pressed again, stops it.
        let bindings: [(Shortcut, @MainActor (AppModel) -> Void)] = [
            (.screenshot, { $0.capture(.screenshot) }),
            (.recording, { $0.toggleRecording() }),
        ]
        let unavailable = bindings.compactMap { shortcut, action -> String? in
            let registered = hotKeys.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in
                if let model = self?.model { action(model) }
            }
            return registered ? nil : shortcut.words
        }
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

/// Builds the one library window. The window is as large as its content
/// needs: small with no captures, taller as captures arrive, until the grid
/// reaches its scroll limit.
@MainActor
enum LibraryWindow {
    static func make(model: AppModel) -> NSWindow {
        let hosting = NSHostingController(rootView: LibraryView().environment(model))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuickShot"
        // The narrow title bar is given to the item actions; the name stays
        // available to the window list and to assistive technology.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Layout.windowWidth, height: Layout.captureBarHeight)
        window.center()
        window.setFrameAutosaveName("QuickShotLibrary")
        return window
    }
}
