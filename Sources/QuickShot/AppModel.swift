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
        case failed(String)
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
        do {
            try library.ensureDirectory()
        } catch {
            notice = .failed("Could not create \(library.directory.path): \(error.localizedDescription)")
        }
        reload()
        watcher = DirectoryWatcher(directory: library.directory) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        if !screenAccess.isGranted() { notice = .permissionNeeded }
    }

    func reload() {
        items = (try? library.items()) ?? []
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
        }
    }

    /// Closes the system picker without saving.
    func cancelCapture() {
        runner.cancel()
    }

    func copy(_ item: CaptureItem) {
        guard CaptureActions.copy(item) else {
            notice = .failed("Could not copy \(item.url.lastPathComponent) to the clipboard.")
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
            notice = .failed("Could not move \(item.url.lastPathComponent) to the Trash: \(error.localizedDescription)")
        }
        reload()
    }

    private func handle(_ result: CaptureResult?) {
        switch result {
        case .captured(let files):
            let outcome = CaptureFiler.fileAll(files, into: library.directory)
            reload()
            if let newest = outcome.filed.last { selection = newest }
            if !outcome.problems.isEmpty { notice = .failed(outcome.problems.joined(separator: " ")) }
            showLibrary()
        case .cancelled:
            notice = .nothingSaved
            if libraryWasVisible { showLibrary() }
        case .failed(let message):
            notice = .failed(message)
            showLibrary()
        case nil:
            break
        }
    }
}
