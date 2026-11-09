import AppKit
import CoreGraphics
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
        /// Something went wrong. The text is shown as written.
        case problem(String)
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
    /// The seconds left before the recording starts, while counting down.
    private(set) var countdown: Int?
    static let presetKey = "recordingPreset"
    static let targetKey = "recordingTarget"
    static let countdownKey = "recordingCountsDown"
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
    @ObservationIgnored var notify: @MainActor (CaptureItem) -> Void = { _ in }
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
            var final = result
            if mode == .recording, preset == .quick, case .captured? = result {
                isSavingRecording = true
                final = await shrunk(result)
                isSavingRecording = false
            }
            activeCapture = nil
            handle(final)
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
        if recordingTarget == .app { appRecorder.stop(); return }
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
                try? FileManager.default.removeItem(at: file)
                kept.append(small)
            } catch {
                kept.append(file)
                problems.append("Kept the full-size recording: \(error).")
            }
        }
        if !problems.isEmpty { notice = .problem(problems.joined(separator: " ")) }
        return .captured(kept)
    }

    private func handle(_ result: CaptureResult?) {
        switch result {
        case .captured(let files):
            let outcome = CaptureFiler.fileAll(files, into: library.directory)
            reload()
            if let newest = outcome.filed.last {
                selection = newest.lastPathComponent
                if let item = selectedItem { notify(item) }
            }
            if !outcome.problems.isEmpty {
                let earlier: [String] = if case .problem(let text)? = notice { [text] } else { [] }
                notice = .problem((earlier + outcome.problems).joined(separator: " "))
            }
            // The notification says it was saved; the window comes back only
            // where it was, or when there is a problem to read.
            if libraryWasVisible || !outcome.problems.isEmpty { showLibrary() }
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
