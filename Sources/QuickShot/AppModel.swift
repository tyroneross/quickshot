import AppKit
import CoreGraphics
import ImageIO
import Observation
import OSLog
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
        /// Something went wrong. The text is shown as written, with a Try
        /// Again button when the action can simply be repeated.
        case problem(String, retry: Retry? = nil)
    }

    /// An action a notice offers to repeat. Equal to itself only, so a notice
    /// that gains or loses its retry counts as a change.
    struct Retry: Equatable {
        private let id = UUID()
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        static func == (a: Retry, b: Retry) -> Bool { a.id == b.id }
    }

    private(set) var items: [CaptureItem] = []
    /// The capture in progress, if any.
    private(set) var activeCapture: CaptureMode?
    /// True from the moment the recorder has written its movie until the
    /// shrunk copy is filed. Stop and Cancel do nothing in this phase: the
    /// recording is already made, and cancelling would only lose the export.
    private(set) var isSavingRecording = false
    /// How Record records. Kept between launches.
    var recordingPreset: RecordingPreset {
        didSet { defaults.set(recordingPreset.rawValue, forKey: Self.presetKey) }
    }
    /// What Record records: the screen, an area, or one app. Kept between
    /// launches, and the shortcut repeats it.
    var recordingTarget: RecordingTarget {
        didSet { defaults.set(recordingTarget.rawValue, forKey: Self.targetKey) }
    }
    /// Whether a recording counts down from three before it starts.
    var countsDown: Bool {
        didSet { defaults.set(countsDown, forKey: Self.countdownKey) }
    }
    /// How much detail a screenshot keeps. Lower by default.
    var fidelity: ScreenshotFidelity {
        didSet { defaults.set(fidelity.rawValue, forKey: Self.fidelityKey) }
    }
    /// Whether every capture is also put on the clipboard. On by default.
    var copiesToClipboard: Bool {
        didSet { defaults.set(copiesToClipboard, forKey: Self.copyKey) }
    }
    /// The seconds left before the recording starts, while counting down.
    private(set) var countdown: Int?
    static let presetKey = "recordingPreset"
    static let targetKey = "recordingTarget"
    static let countdownKey = "recordingCountsDown"
    static let fidelityKey = "screenshotFidelity"
    static let copyKey = "copiesToClipboard"
    static let countdownSeconds = 3
    var isCapturing: Bool { activeCapture != nil }
    var notice: Notice?
    var selection: CaptureItem.ID?
    /// Whether macOS has been asked for Screen Recording access this launch.
    /// After that, the step left is reopening the app.
    private(set) var askedForAccess = false
    /// True from the moment a reopen is requested until it fails, so a second
    /// click cannot start a second copy.
    private(set) var isReopening = false
    /// Starts a new copy of the app; reports an error text on failure.
    @ObservationIgnored var launchNewInstance: @MainActor (@escaping @MainActor (String?) -> Void) -> Void = { CaptureActions.launchNewInstance(completion: $0) }
    /// Quits this copy once the new one is running.
    @ObservationIgnored var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    let library: CaptureLibrary

    @ObservationIgnored private let runner: CaptureRunner
    @ObservationIgnored private let screenAccess: ScreenAccess
    @ObservationIgnored private let defaults: UserDefaults
    /// Shrinks a Quick recording. Injectable: tests use a stand-in.
    @ObservationIgnored var shrink: @Sendable (URL) async throws -> URL = { try await MovieShrinker.shrink($0) }
    /// Tells the person a capture was saved, without raising the window.
    /// Returns `false` when it could not, so the window is shown instead.
    @ObservationIgnored var notify: @MainActor (CaptureItem, _ copied: Bool) async -> Bool = { _, _ in false }
    /// Halves a Retina screenshot. Injectable: tests use a stand-in.
    @ObservationIgnored var shrinkImage: @Sendable (URL) throws -> URL = { try ImageShrinker.shrink($0) }
    /// Frames what was captured: the given area, or every screen when `nil`.
    /// Injectable: tests record the calls.
    @ObservationIgnored var flash: @MainActor (NSRect?) -> Void = { rect in
        if let rect { CaptureFlash.show(around: rect) } else { CaptureFlash.showScreens() }
    }
    /// Watches the mouse while the crosshair is up, for the flash.
    @ObservationIgnored var selectionTracker = SelectionTracker()
    /// Puts a capture on the clipboard. Injectable: tests use a scratch board.
    @ObservationIgnored var copyToClipboard: @MainActor (CaptureItem) -> Bool = { CaptureActions.copy($0) }
    /// Records one app or window. Injectable: tests use a stand-in.
    @ObservationIgnored var appRecorder: any AppRecording = WindowRecorder()
    /// One second of the countdown. Tests shorten it.
    @ObservationIgnored var countdownTick: Duration = .seconds(1)
    /// How long the window is given to leave the screen before a full-screen
    /// capture, so QuickShot is not in its own picture.
    static let fullScreenDelay: Duration = .milliseconds(300)
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var libraryWasVisible = false
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [() -> Void] = []
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    /// One line per capture in the system log, so a capture that goes wrong
    /// can be diagnosed afterwards:
    /// `log show --last 10m --predicate 'subsystem == "ai.rosslabs.quickshot"'`
    @ObservationIgnored private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.rosslabs.quickshot", category: "capture")

    /// Window control, set by the app delegate.
    @ObservationIgnored var showLibrary: () -> Void = {}
    @ObservationIgnored var hideLibrary: () -> Void = {}
    @ObservationIgnored var isLibraryVisible: () -> Bool = { false }
    /// Opens the box editor for a picture. Set by the app delegate; tests record it.
    @ObservationIgnored var openEditor: (CaptureItem) -> Void = { _ in }

    /// The capture most recently copied, shown as "Copied" for a moment.
    private(set) var copiedItem: CaptureItem.ID?

    init(
        library: CaptureLibrary = CaptureLibrary(),
        runner: CaptureRunner = CaptureRunner(),
        screenAccess: ScreenAccess = .system,
        defaults: UserDefaults = .standard
    ) {
        self.library = library
        self.runner = runner
        self.screenAccess = screenAccess
        self.defaults = defaults
        self.recordingPreset = defaults.string(forKey: Self.presetKey).flatMap(RecordingPreset.init) ?? .quick
        self.recordingTarget = defaults.string(forKey: Self.targetKey).flatMap(RecordingTarget.init) ?? .screen
        self.countsDown = defaults.object(forKey: Self.countdownKey) as? Bool ?? true
        self.fidelity = defaults.string(forKey: Self.fidelityKey).flatMap(ScreenshotFidelity.init) ?? .lower
        self.copiesToClipboard = defaults.object(forKey: Self.copyKey) as? Bool ?? true
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
        watcher = DirectoryWatcher(directory: library.directory) { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                // A moved or deleted folder leaves the watcher on the old one,
                // even if another folder now sits at the same path.
                if change == .folderGone {
                    try? self.library.ensureDirectory()
                    self.watch()
                }
                self.reload()
            }
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

    /// Records what `recordingTarget` names, with the remembered options.
    func record(_ target: RecordingTarget) {
        recordingTarget = target
        capture(.recording)
    }

    /// Opens the system picker. Ignored while a capture is already running.
    func capture(_ mode: CaptureMode) {
        // Not while the app is reopening: this copy is about to quit.
        guard !isCapturing, !isReopening else { return }
        guard screenAccess.isGranted() else {
            // Without access the tool can exit cleanly with only the desktop
            // wallpaper in the image, so nothing is captured until it is granted.
            log.notice("capture refused: \(mode.rawValue, privacy: .public), Screen Recording not granted")
            requestScreenAccess()
            notice = .permissionNeeded
            showLibrary()
            return
        }
        notice = nil
        activeCapture = mode
        // Keep QuickShot's own window out of the picture.
        libraryWasVisible = isLibraryVisible()
        hideLibrary()
        if mode == .area { selectionTracker.start() }
        let preset = recordingPreset
        let target = recordingTarget
        let countsDown = countsDown
        log.notice("capture start: \(mode.rawValue, privacy: .public) \(mode == .recording ? "\(target.rawValue) \(preset.rawValue)" : "", privacy: .public)")
        captureTask = Task {
            if mode == .fullScreen {
                // Give the window time to leave the screen. A cancel here ends
                // the capture before the tool starts.
                try? await Task.sleep(for: Self.fullScreenDelay)
            }
            let result: CaptureResult?
            if Task.isCancelled {
                result = .cancelled
            } else if mode == .recording, target == .app {
                result = await recordApp(preset: preset, countsDown: countsDown)
            } else {
                if mode == .recording, countsDown { await countDown() }
                result = Task.isCancelled ? .cancelled : await runner.run(mode, target: target, preset: preset)
            }
            log.notice("capture end: \(mode.rawValue, privacy: .public) -> \(String(describing: result), privacy: .public)")
            selectionTracker.stop()
            var final = result
            if mode == .recording, preset == .quick, case .captured? = result {
                isSavingRecording = true
                final = await shrunk(result)
                isSavingRecording = false
            } else if mode != .recording, fidelity == .lower, case .captured? = result {
                final = await shrunkImages(result)
            }
            activeCapture = nil
            handle(final, mode: mode)
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// Asks macOS for Screen Recording access (the system shows its prompt once).
    func requestScreenAccess() {
        screenAccess.request()
        askedForAccess = true
    }

    /// Reopens the app so a new Screen Recording grant takes effect. This copy
    /// quits only after the new one has started; if that fails it stays open
    /// and says why.
    func reopen() {
        // Not during a capture: quitting would then ask to keep it, and
        // keeping it would leave two copies of the app running.
        guard !isReopening, !isCapturing else { return }
        isReopening = true
        launchNewInstance { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.isReopening = false
                self.notice = .problem("QuickShot could not reopen itself: \(failure) Quit and open it again by hand.")
            } else {
                self.quit()
            }
        }
    }

    /// Closes the system picker without saving. Cancelling the task covers
    /// every moment of a capture, including before the tool has started.
    func cancelCapture() {
        guard !isSavingRecording else { return }
        if activeCapture == .recording, recordingTarget == .app { appRecorder.cancel() }
        captureTask?.cancel()
    }

    /// Ends the recording in progress and keeps it.
    func stopRecording() {
        guard activeCapture == .recording, !isSavingRecording else { return }
        // Stop during the countdown: nothing is recorded yet, so cancel.
        if countdown != nil { captureTask?.cancel(); return }
        if recordingTarget == .app {
            // Before frames are being written there is nothing to keep, and the
            // request may not even have reached the recorder yet: cancel.
            if appRecorder.isRecording { appRecorder.stop() } else { cancelCapture() }
            return
        }
        // Stop pressed before the recorder has started: nothing is recorded
        // yet, so cancel it rather than lose the request.
        if !runner.finishRecording() { captureTask?.cancel() }
    }

    /// Starts a recording, or stops the one in progress.
    func toggleRecording() {
        if activeCapture == .recording {
            stopRecording()
        } else {
            capture(.recording)
        }
    }

    /// Runs `action` once no capture is running: now if idle, otherwise right
    /// after the running capture's result has been handled.
    func whenIdle(_ action: @escaping () -> Void) {
        guard isCapturing else { return action() }
        idleWaiters.append(action)
    }

    func copy(_ item: CaptureItem) {
        guard copyToClipboard(item) else {
            notice = .problem("Could not copy \(item.url.lastPathComponent) to the clipboard.",
                              retry: Retry { [weak self] in self?.notice = nil; self?.copy(item) })
            return
        }
        notice = nil
        markCopied(item.id)
    }

    /// Shows "Copied" on the item for a moment.
    private func markCopied(_ id: CaptureItem.ID) {
        copiedItem = id
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copiedItem = nil }
        }
    }

    /// Moves the capture to the Trash and keeps a selection: the next item,
    /// or the previous one at the end, so the toolbar stays usable.
    func trash(_ item: CaptureItem) {
        let index = items.firstIndex(of: item)
        do {
            try library.trash(item)
        } catch {
            notice = .problem("Not moved to the Trash: \(item.url.lastPathComponent) could not be moved (\(error.localizedDescription)). Close any app that has it open.",
                              retry: Retry { [weak self] in self?.notice = nil; self?.trash(item) })
        }
        reload()
        if selection == nil, let index, !items.isEmpty {
            selection = items[min(index, items.count - 1)].id
        }
    }

    /// Opens a picture in the box editor; a recording opens in QuickTime
    /// Player as before. A file that has gone is reported, not opened.
    func annotate(_ item: CaptureItem) {
        guard item.kind == .image else { CaptureActions.open(item); return }
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            notice = .problem("Could not open \(item.url.lastPathComponent): the file has moved or been deleted.")
            reload()
            return
        }
        openEditor(item)
    }

    /// The editor saved a marked copy and put it on the clipboard: show it
    /// selected, with the Copied receipt.
    func didMark(_ url: URL) {
        reload()
        selection = url.lastPathComponent
        markCopied(url.lastPathComponent)
    }

    /// Three, two, one. A cancel during the count ends the capture before
    /// anything is recorded.
    private func countDown() async {
        for left in stride(from: Self.countdownSeconds, through: 1, by: -1) {
            if Task.isCancelled { break }
            countdown = left
            try? await Task.sleep(for: countdownTick)
        }
        countdown = nil
    }

    /// The picker first, so the count runs on the chosen window.
    private func recordApp(preset: RecordingPreset, countsDown: Bool) async -> CaptureResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShot-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create a scratch folder: \(error.localizedDescription)")
        }
        let output = scratch.appendingPathComponent(CaptureCommand.requestedFileName(for: .recording))
        // A cancel reaches the recorder through `cancelCapture()`.
        let result = await appRecorder.record(to: output, preset: preset) { [weak self] in
            guard let self, countsDown else { return !Task.isCancelled }
            await countDown()
            return !Task.isCancelled
        }
        if case .captured = result {} else { rmdir(scratch.path) }
        return result
    }

    /// Replaces each Retina screenshot with its 1x version. A picture that
    /// cannot be shrunk is kept as taken.
    private func shrunkImages(_ result: CaptureResult?) async -> CaptureResult? {
        guard case .captured(let files)? = result else { return result }
        let shrink = shrinkImage
        // Decoding and re-encoding a Retina screenshot takes a noticeable
        // moment; the window and the flash must not wait for it.
        return await Task.detached(priority: .userInitiated) {
            var kept: [URL] = []
            for file in files {
                guard CaptureFormat.detect(file)?.kind == .image, let small = try? shrink(file) else { kept.append(file); continue }
                if small != file { try? FileManager.default.removeItem(at: file) }
                kept.append(small)
            }
            return CaptureResult.captured(kept)
        }.value
    }

    /// Replaces each movie in a Quick recording with its 1080p version. If a
    /// movie cannot be shrunk it is kept as recorded and the reason is shown.
    private func shrunk(_ result: CaptureResult?) async -> CaptureResult? {
        guard case .captured(let files)? = result else { return result }
        var kept: [URL] = []
        var problems: [String] = []
        for file in files {
            guard CaptureFormat.detect(file)?.kind == .video else { kept.append(file); continue }
            do {
                let small = try await shrink(file)
                // The shrinker returns the source itself when it already fits.
                if small != file { try? FileManager.default.removeItem(at: file) }
                kept.append(small)
            } catch {
                kept.append(file)
                problems.append("Kept the full-size recording: \(error).")
            }
        }
        if !problems.isEmpty { notice = .problem(problems.joined(separator: " ")) }
        return .captured(kept)
    }

    /// An image's size in points (its pixels over its density), for the frame.
    static func pointSize(of image: URL) -> NSSize? {
        guard let reader = CGImageSourceCreateWithURL(image as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let scale = max(1, (dpi / 72).rounded())
        return NSSize(width: width / scale, height: height / scale)
    }

    /// Whether the newest capture went to the clipboard, for the notification.
    private(set) var lastCopied = false

    private func handle(_ result: CaptureResult?, mode: CaptureMode) {
        switch result {
        case .captured(let files):
            switch mode {
            case .fullScreen: flash(nil)
            case .area:
                let area = selectionTracker.selection(imageSize: files.first.flatMap(Self.pointSize))
                log.notice("flash area: \(area.map { NSStringFromRect($0) } ?? "unknown", privacy: .public)")
                flash(area)
            case .recording: break
            }
            let outcome = CaptureFiler.fileAll(files, into: library.directory)
            reload()
            if !outcome.problems.isEmpty {
                let earlier: [String] = if case .problem(let text, _)? = notice { [text] } else { [] }
                notice = .problem((earlier + outcome.problems).joined(separator: " "))
            }
            let hasProblem: Bool = if case .problem? = notice { true } else { false }
            let item = outcome.filed.last.flatMap { newest in
                selection = newest.lastPathComponent
                return selectedItem
            }
            lastCopied = false
            if copiesToClipboard, let item {
                lastCopied = copyToClipboard(item)
                if lastCopied { copiedItem = item.id }
            }
            // The window comes back where it was, or when there is a problem
            // to read. Otherwise the notification says it was saved; if that
            // cannot reach the person, the window does.
            if libraryWasVisible || hasProblem {
                showLibrary()
            } else if let item {
                let copied = lastCopied
                Task { if await !notify(item, copied) { showLibrary() } }
            }
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
