import AppKit
import CoreGraphics
import Observation
import QuickShotCore

/// Whether macOS lets this app capture the screen. Injectable so the model
/// does not depend on the machine's privacy settings.
struct ScreenAccess: Sendable {
    var isGranted: @Sendable () -> Bool
    var request: @Sendable () -> Void

    static let system = ScreenAccess(
        isGranted: { CGPreflightScreenCaptureAccess() },
        request: { _ = CGRequestScreenCaptureAccess() }
    )
}

/// The app's state: the captures on disk, whether a capture is running, and
/// the one notice the person needs to see.
@MainActor
@Observable
final class AppModel {
    enum Notice: Equatable {
        case permissionNeeded
        case nothingSaved
        /// Something went wrong. The text is shown as written.
        case problem(String)
    }

    private(set) var items: [CaptureItem] = []
    private(set) var isCapturing = false
    var notice: Notice?
    var selection: CaptureItem.ID?

    let library: CaptureLibrary

    @ObservationIgnored private let runner: CaptureRunner
    @ObservationIgnored private let screenAccess: ScreenAccess
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var libraryWasVisible = false
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [() -> Void] = []

    /// Window control, set by the app delegate.
    @ObservationIgnored var showLibrary: () -> Void = {}
    @ObservationIgnored var hideLibrary: () -> Void = {}
    @ObservationIgnored var isLibraryVisible: () -> Bool = { false }

    /// The capture most recently copied, shown as "Copied" for a moment.
    private(set) var copiedItem: CaptureItem.ID?

    init(
        library: CaptureLibrary = CaptureLibrary(),
        runner: CaptureRunner = CaptureRunner(),
        screenAccess: ScreenAccess = .system
    ) {
        self.library = library
        self.runner = runner
        self.screenAccess = screenAccess
    }

    var selectedItem: CaptureItem? {
        items.first { $0.id == selection }
    }

    func start() {
        try? library.ensureDirectory() // a failure surfaces through reload()
        watch()
        reload()
        if !screenAccess.isGranted() { notice = .permissionNeeded }
    }

    private func watch() {
        watcher = DirectoryWatcher(directory: library.directory) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Re-reads the folder. If it has gone (deleted or moved in Finder), it is
    /// created again and watched afresh; a folder that still cannot be read is
    /// reported instead of being shown as empty.
    func reload() {
        do {
            items = try library.items()
        } catch {
            do {
                try library.ensureDirectory()
                watch()
                items = try library.items()
            } catch {
                items = []
                notice = .problem("Could not read \(library.directory.path): \(error.localizedDescription)")
            }
        }
        if let selection, !items.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    /// Clears the permission notice once access has been granted.
    func refreshAccess() {
        if notice == .permissionNeeded, screenAccess.isGranted() { notice = nil }
    }

    /// Opens the system picker. Ignored while a capture is already running.
    func capture(_ mode: CaptureMode) {
        guard !isCapturing else { return }
        guard screenAccess.isGranted() else {
            // Without access the tool can exit cleanly with only the desktop
            // wallpaper in the image, so nothing is captured until it is granted.
            screenAccess.request()
            notice = .permissionNeeded
            showLibrary()
            return
        }
        notice = nil
        isCapturing = true
        // Keep QuickShot's own window out of the picture.
        libraryWasVisible = isLibraryVisible()
        hideLibrary()
        Task {
            let result = await runner.run(mode)
            isCapturing = false
            handle(result)
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// Closes the system picker without saving.
    func cancelCapture() {
        runner.cancel()
    }

    /// Runs `action` once no capture is running: now if idle, otherwise right
    /// after the running capture's result has been handled.
    func whenIdle(_ action: @escaping () -> Void) {
        guard isCapturing else { return action() }
        idleWaiters.append(action)
    }

    func copy(_ item: CaptureItem) {
        guard CaptureActions.copy(item) else {
            notice = .problem("Could not copy \(item.url.lastPathComponent) to the clipboard.")
            return
        }
        copiedItem = item.id
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copiedItem = nil }
        }
    }

    func trash(_ item: CaptureItem) {
        do {
            try library.trash(item)
        } catch {
            notice = .problem("Could not move \(item.url.lastPathComponent) to the Trash: \(error.localizedDescription)")
        }
        reload()
    }

    private func handle(_ result: CaptureResult?) {
        switch result {
        case .captured(let files):
            let outcome = CaptureFiler.fileAll(files, into: library.directory)
            reload()
            if let newest = outcome.filed.last { selection = newest.lastPathComponent }
            if !outcome.problems.isEmpty { notice = .problem(outcome.problems.joined(separator: " ")) }
            showLibrary()
        case .cancelled:
            notice = .nothingSaved
            if libraryWasVisible { showLibrary() }
        case .failed(let message):
            notice = .problem("Capture failed. The system capture tool reported: \(message)")
            showLibrary()
        case nil:
            break
        }
    }
}
