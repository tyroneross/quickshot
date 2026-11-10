import AppKit
import ClipboardCore
import os
import QuickShotCore
import SwiftUI

@main
struct QuickShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(delegateClipboard: delegate.clipboard).environment(delegate.model)
        }
        MenuBarExtra {
            MenuContent(delegate: delegate).environment(delegate.model)
        } label: {
            MenuBarLabel().environment(delegate.model)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Says what is true: counting down and saving are not recording.
        let (symbol, label): (String, String) = if model.activeCapture == .recording, let left = model.countdown {
            ("timer", "QuickShot, recording in \(left)")
        } else if model.activeCapture == .recording, model.isSavingRecording {
            ("camera", "QuickShot, saving the recording")
        } else if model.activeCapture == .recording {
            ("record.circle.fill", "QuickShot, recording")
        } else {
            ("camera", "QuickShot")
        }
        Image(systemName: symbol).accessibilityLabel(label)
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    let delegate: AppDelegate

    var body: some View {
        switch model.activeCapture {
        case .recording where model.isSavingRecording:
            Text("Saving the recording")
        case .recording where model.countdown != nil:
            Button("Cancel Recording") { model.cancelCapture() }
                .keyboardShortcut(Shortcut.recording.keyboardShortcut)
        case .recording:
            Button("Stop Recording") { model.stopRecording() }
                .keyboardShortcut(Shortcut.recording.keyboardShortcut)
        case .area, .fullScreen:
            Button("Cancel Capture") { model.cancelCapture() }
        case nil:
            Button("Capture Full Screen") { model.capture(.fullScreen) }
                .keyboardShortcut(Shortcut.fullScreen.keyboardShortcut)
            Button("Capture Area") { model.capture(.area) }
                .keyboardShortcut(Shortcut.area.keyboardShortcut)
            Menu("Record") {
                ForEach(RecordingTarget.allCases, id: \.self) { target in
                    Button(target.title) { model.record(target) }
                        .keyboardShortcut(target == model.recordingTarget ? Shortcut.recording.keyboardShortcut : nil)
                }
            }
            @Bindable var model = model
            Picker("Recording Preset", selection: $model.recordingPreset) {
                ForEach(RecordingPreset.allCases, id: \.self) { preset in
                    Text(preset.menuTitle).tag(preset)
                }
            }
            Toggle("Count Down \(AppModel.countdownSeconds) Seconds First", isOn: $model.countsDown)
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
        }
        Divider()
        Button("Show Captures") { model.showLibrary() }
        Button("Open Captures Folder") { CaptureActions.openFolder(model.library.directory) }
        if let clipboard = delegate.clipboard {
            Divider()
            Button("Show Clipboard") { delegate.showClipboard() }
                .keyboardShortcut(Shortcut.clipboard.keyboardShortcut)
            Button(clipboard.isPaused ? "Resume Clipboard History" : "Pause Clipboard History") { clipboard.togglePause() }
        }
        Divider()
        Button("Quit QuickShot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// The clipboard library, or `nil` when its store could not be opened.
    private(set) var clipboard: ClipboardModel?
    private let hotKeys = HotKeyCenter()
    private let notifier = CaptureNotifier()
    /// One line per shortcut press and per registration, so "the shortcut
    /// does nothing" can be split into "never arrived" and "arrived, then
    /// refused" from the system log.
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.rosslabs.quickshot", category: "hotkey")
    private var window: NSWindow?
    private var clipboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.showLibrary = { [weak self] in self?.showLibrary() }
        model.hideLibrary = { [weak self] in self?.window?.orderOut(nil) }
        model.isLibraryVisible = { [weak self] in self?.window?.isVisible ?? false }
        model.notify = { [weak self] item, copied in await self?.notifier.notify(item, copied: copied) ?? false }
        notifier.open = { [weak self] id in
            guard let self else { return }
            model.selection = id
            showLibrary()
        }
        model.start()
        startClipboard()
        registerHotKeys()
        showLibrary()
    }

    private func startClipboard() {
        do {
            let store = try ClipStore(directory: ClipStore.defaultDirectory)
            let clipboard = ClipboardModel(store: store, captures: { [model] in model.items })
            clipboard.start()
            self.clipboard = clipboard
        } catch {
            model.notice = .problem("Clipboard history is off: its store could not be opened (\(error.localizedDescription)).")
        }
    }

    func showClipboard() {
        guard let clipboard else { return }
        if clipboardWindow == nil { clipboardWindow = ClipboardWindow.make(model: clipboard) }
        NSApp.activate()
        clipboardWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Captures", action: #selector(showCapturesFromDock), keyEquivalent: "")
        if clipboard != nil {
            menu.addItem(withTitle: "Show Clipboard", action: #selector(showClipboardFromDock), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func showCapturesFromDock() { showLibrary() }
    @objc private func showClipboardFromDock() { showClipboard() }

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
        if model.isSavingRecording {
            // The recording is made; only the small copy is being written.
            model.whenIdle { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        if model.countdown != nil {
            // Nothing is recorded yet: there is nothing to keep or to ask about.
            model.cancelCapture()
            model.whenIdle { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        let alert = NSAlert()
        switch active {
        case .recording:
            alert.messageText = "A recording is in progress"
            alert.informativeText = "Quitting stops the recording and saves it to QuickShot."
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Stop, Save and Quit")
        case .area, .fullScreen:
            alert.messageText = "A screenshot is in progress"
            alert.informativeText = "Quitting closes the screenshot without saving."
            alert.addButton(withTitle: "Keep Going")
            alert.addButton(withTitle: "Quit Anyway")
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // Wait for the tool to exit so its result is filed before the app goes.
        switch active {
        case .recording: model.stopRecording()
        case .area, .fullScreen: model.cancelCapture()
        }
        model.whenIdle { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func registerHotKeys() {
        // The record shortcut starts a recording and, pressed again, stops it.
        let bindings: [(Shortcut, @MainActor (AppDelegate) -> Void)] = [
            (.fullScreen, { $0.model.capture(.fullScreen) }),
            (.area, { $0.model.capture(.area) }),
            (.recording, { $0.model.toggleRecording() }),
            (.clipboard, { $0.showClipboard() }),
        ]
        let unavailable = bindings.compactMap { shortcut, action -> String? in
            let registered = hotKeys.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in
                guard let self else { return }
                log.notice("hot key pressed: \(shortcut.words, privacy: .public)")
                action(self)
            }
            log.notice("hot key \(shortcut.words, privacy: .public) registered: \(registered, privacy: .public)")
            return registered ? nil : shortcut.words
        }
        if !unavailable.isEmpty, model.notice == nil {
            model.notice = .problem("Another app already uses \(unavailable.joined(separator: " and ")). The buttons and the menu bar item still work.")
        }
    }

    private func showLibrary() {
        // Not while a full-screen capture waits for the window to leave the
        // screen: a Dock click or Show Captures now would put it in the picture.
        guard model.activeCapture != .fullScreen else { return }
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
        window.title = "Captures"
        // The narrow title bar is given to the item actions; the name stays
        // available to the window list and to assistive technology.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Layout.windowWidth, height: Layout.captureBarHeight)
        window.center()
        window.setFrameAutosaveName("QuickShotLibrary")
        // Content-sized until the person resizes or zooms it; after that the
        // size is theirs, and the content fills whatever they chose.
        let sizing = SizingHandoff(hosting: hosting)
        window.delegate = sizing
        objc_setAssociatedObject(window, &SizingHandoff.key, sizing, .OBJC_ASSOCIATION_RETAIN)
        return window
    }

    /// Stops the automatic content sizing the first time the person takes
    /// the window's size into their own hands.
    final class SizingHandoff: NSObject, NSWindowDelegate {
        nonisolated(unsafe) static var key = 0
        private let handOver: () -> Void
        init<Content: View>(hosting: NSHostingController<Content>) {
            handOver = { hosting.sizingOptions = [] }
        }

        func windowWillStartLiveResize(_ notification: Notification) { handOver() }

        /// The green button: fill the screen the window is on.
        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
            handOver()
            return window.screen?.visibleFrame ?? defaultFrame
        }
    }
}

/// The few choices that are not on the window itself.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var delegateClipboard: ClipboardModel?
    static let budgets = [256, 512, 1024, 2048, 4096].map { $0 * 1024 * 1024 }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Screenshots") {
                Picker("Fidelity", selection: $model.fidelity) {
                    ForEach(ScreenshotFidelity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Copy every capture to the clipboard", isOn: $model.copiesToClipboard)
            }
            Section("Recordings") {
                Picker("Preset", selection: $model.recordingPreset) {
                    ForEach(RecordingPreset.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Count down \(AppModel.countdownSeconds) seconds before recording", isOn: $model.countsDown)
            }
            if let clipboard = delegateClipboard {
                @Bindable var clipboard = clipboard
                Section("Clipboard history") {
                    Picker("Keep up to", selection: $clipboard.historyBudget) {
                        ForEach(SettingsView.budgets, id: \.self) { bytes in
                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).tag(bytes)
                        }
                    }
                    Text("Older copies go first; items in a collection are always kept.")
                        .font(.subheadline)
                        .foregroundStyle(Color.supportingText)
                }
            }
            Section("Shortcuts") {
                LabeledContent("Full Screen", value: Shortcut.fullScreen.words)
                LabeledContent("Area", value: Shortcut.area.words)
                LabeledContent("Record (last choice)", value: Shortcut.recording.words)
                LabeledContent("Clipboard", value: Shortcut.clipboard.words)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
