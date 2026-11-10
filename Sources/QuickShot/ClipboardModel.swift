import AppKit
import ClipboardCore
import Observation
import QuickShotCore

/// A place in the library's sidebar.
enum LibrarySection: Hashable {
    case history
    case captures
    case collection(Int64)
}

/// One row in the library: something copied, or a QuickShot capture.
enum LibraryEntry: Identifiable, Hashable {
    case clip(ClipItem)
    case capture(CaptureItem)

    var id: String {
        switch self {
        case .clip(let item): "clip-\(item.id)"
        case .capture(let item): "capture-\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .clip(let item): item.title
        case .capture(let item): item.name
        }
    }

    var date: Date {
        switch self {
        case .clip(let item): item.lastCopied
        case .capture(let item): item.created
        }
    }

    /// A word for what the entry is, shown beside its symbol.
    var kindWord: String {
        switch self {
        case .clip(let item):
            switch item.kind {
            case .text: "Text"
            case .image: "Image"
            case .files: item.filePaths.count == 1 ? "File" : "Files"
            }
        case .capture(let item): item.kind == .image ? "Screenshot" : "Recording"
        }
    }

    var symbol: String {
        switch self {
        case .clip(let item):
            switch item.kind {
            case .text: "text.alignleft"
            case .image: "photo"
            case .files: "doc"
            }
        case .capture(let item): item.kind == .image ? "camera" : "video"
        }
    }
}

/// Why new copies are not being recorded, when they are not.
enum LibraryStatus: Equatable {
    /// macOS is set to deny this app the clipboard.
    case blocked
    /// The person paused history.
    case paused

    var message: String {
        switch self {
        case .blocked: "New copies are not recorded: macOS denies QuickShot the clipboard. Allow it under Paste from Other Apps."
        case .paused: "Clipboard history is paused. New copies are not recorded."
        }
    }

    var actionTitle: String {
        switch self {
        case .blocked: "Open Settings"
        case .paused: "Resume"
        }
    }
}

/// The clipboard library's state: what is listed, what is selected, and
/// whether history is being recorded.
@MainActor
@Observable
final class ClipboardModel {
    private(set) var collections: [ClipCollection] = []
    private(set) var clips: [ClipItem] = []
    private(set) var monitorState: ClipboardMonitor.State = .running
    /// The entry most recently copied, shown as "Copied" for a moment.
    private(set) var copiedEntry: String?
    /// What the last export wrote, as a receipt.
    private(set) var receipt: String?
    var problem: String?
    var selection: String?
    var searchText = "" { didSet { reload() } }
    var section: LibrarySection = .history {
        didSet {
            guard section != oldValue else { return }
            selection = nil
            reload()
        }
    }

    let store: ClipStore
    @ObservationIgnored private(set) var monitor: ClipboardMonitor!
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let captures: () -> [CaptureItem]
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    /// Where "history is paused" is remembered between launches.
    static let pausedKey = "clipboardHistoryPaused"

    /// - Parameter captures: QuickShot's captures, listed in place from their folder.
    init(
        store: ClipStore,
        pasteboard: NSPasteboard = .general,
        captures: @escaping () -> [CaptureItem],
        defaults: UserDefaults = .standard,
        frontmostApp: @escaping () -> String? = ClipboardMonitor.systemFrontmostApp,
        accessDenied: (() -> Bool)? = nil
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.captures = captures
        self.defaults = defaults
        monitor = ClipboardMonitor(
            pasteboard: pasteboard, store: store, frontmostApp: frontmostApp, accessDenied: accessDenied
        ) { [weak self] in
            guard let self else { return }
            self.monitorState = self.monitor.state
            self.reload()
        }
        // A pause survives a relaunch: history must not resume on its own.
        if defaults.bool(forKey: Self.pausedKey) {
            monitor.isPaused = true
            monitorState = monitor.state
        }
    }

    /// Clears expired history, loads the lists and starts recording copies.
    /// Expiry runs again once a day while the app stays open, since it may
    /// never be relaunched.
    func start() {
        tidy()
        reload()
        monitor.start()
        housekeeping?.cancel()
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.housekeepingInterval)
                guard let self, !Task.isCancelled else { return }
                tidy()
                reload()
            }
        }
    }

    static let housekeepingInterval: Duration = .seconds(24 * 60 * 60)
    @ObservationIgnored private var housekeeping: Task<Void, Never>?

    isolated deinit { housekeeping?.cancel() }

    /// Expiry by age, then the size budget, then the log folded into the file.
    func tidy() {
        attempt { _ = try store.expire() }
        attempt { _ = try store.trim(toBudget: historyBudget) }
        attempt { try store.checkpoint() }
    }

    /// The most history to keep, in bytes. Remembered.
    var historyBudget: Int {
        get { defaults.object(forKey: Self.budgetKey) as? Int ?? ClipStore.defaultBudgetBytes }
        set { defaults.set(newValue, forKey: Self.budgetKey); tidy(); reload() }
    }
    static let budgetKey = "clipboardHistoryBudgetBytes"

    var entries: [LibraryEntry] {
        guard section == .captures else { return clips.map(LibraryEntry.clip) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return captures()
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map(LibraryEntry.capture)
    }

    var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selection }
    }

    var isPaused: Bool { monitorState == .paused }

    /// The notice the library shows while copies are not being recorded.
    var status: LibraryStatus? {
        switch monitorState {
        case .running: nil
        case .paused: .paused
        case .blocked: .blocked
        }
    }

    func reload() {
        attempt {
            collections = try store.collections()
            switch section {
            case .history: clips = try store.items(in: .history, matching: searchText)
            case .collection(let id): clips = try store.items(in: .collection(id), matching: searchText)
            case .captures: clips = []
            }
        }
        if case .collection(let id) = section, !collections.contains(where: { $0.id == id }) {
            section = .history
        }
    }

    /// The app came to the front: the person may have changed the clipboard
    /// permission, so the next check reads it again.
    func refreshAccess() {
        monitor.checkAccessSoon()
        monitor.tick()
        monitorState = monitor.state
    }

    func togglePause() {
        monitor.isPaused.toggle()
        monitorState = monitor.state
        defaults.set(monitor.isPaused, forKey: Self.pausedKey)
    }

    // MARK: Actions on an entry

    /// Puts the entry on the clipboard. The copy is marked as QuickShot's own,
    /// so it is not recorded again and the list does not reorder.
    func copy(_ entry: LibraryEntry) {
        let written: Bool
        switch entry {
        case .clip(let item): written = ClipboardWriter.write(item, from: store, to: pasteboard)
        case .capture(let item): written = CaptureActions.copy(item, to: pasteboard)
        }
        guard written else {
            problem = "Could not copy \(entry.title). Its file may have been moved or deleted."
            return
        }
        copiedEntry = entry.id
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copiedEntry = nil }
        }
    }

    /// Saves a copy of the entry into a folder. The entry stays where it is.
    /// Files are copied off the main thread, since a recording can be large
    /// and the destination slow; the receipt appears when the copy is done.
    @discardableResult
    func export(_ entry: LibraryEntry, to folder: URL) -> Task<Void, Never> {
        // Only plain values cross to the background task; every write to the
        // destination happens there.
        let work: @Sendable () throws -> [URL]
        switch entry {
        case .clip(let item):
            switch item.kind {
            case .text:
                let text = item.text
                work = { [try ClipExporter.exportText(text, to: folder)] }
            case .image:
                guard let source = store.imageURL(for: item) else {
                    problem = "The image file is missing, so nothing was saved."
                    return Task {}
                }
                work = { [try ClipExporter.exportImage(at: source, to: folder)] }
            case .files:
                let paths = item.filePaths
                work = { try ClipExporter.exportFiles(paths, to: folder) }
            }
        case .capture(let item):
            let source = item.url
            work = { [try ClipExporter.copy(source, to: folder)] }
        }
        return Task {
            do {
                let written = try await Task.detached(operation: work).value
                guard let first = written.first else { return }
                let place = (folder.path as NSString).abbreviatingWithTildeInPath
                receipt = written.count == 1
                    ? "Saved a copy as \(first.lastPathComponent) in \(place)."
                    : "Saved \(written.count) copies in \(place)."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func collectionIDs(for entry: LibraryEntry) -> Set<Int64> {
        guard let item = clipItem(for: entry, create: false) else { return [] }
        return (try? store.collectionIDs(containing: item)) ?? []
    }

    /// Adds the entry to a collection. A capture is added as a reference to
    /// its file; the file is not copied.
    func add(_ entry: LibraryEntry, to collection: ClipCollection) {
        attempt {
            guard let item = clipItem(for: entry, create: true) else { return }
            try store.add(item, to: collection)
        }
        reload()
    }

    func remove(_ entry: LibraryEntry, from collection: ClipCollection) {
        attempt {
            guard let item = clipItem(for: entry, create: false) else { return }
            try store.remove(item, from: collection)
        }
        reload()
    }

    /// Copies a few selected words, marked as QuickShot's own write so they
    /// are not recorded as a new item.
    func copySelectedText(_ text: String) {
        ClipboardWriter.write(text: text, to: pasteboard)
    }

    /// Whether deleting the entry also takes it out of a collection, where the
    /// person put it to keep it. That deserves a confirmation.
    func deletionRemovesSavedItem(_ entry: LibraryEntry) -> Bool {
        guard case .clip = entry else { return false }
        return !collectionIDs(for: entry).isEmpty
    }

    /// Removes a copied item from history and every collection. Captures are
    /// files and are removed from the captures window, not from here.
    func delete(_ entry: LibraryEntry) {
        guard case .clip(let item) = entry else { return }
        attempt { try store.delete(item) }
        if selection == entry.id { selection = nil }
        reload()
    }

    // MARK: Collections

    @discardableResult
    func createCollection(named name: String) -> ClipCollection? {
        var created: ClipCollection?
        attempt { created = try store.createCollection(named: name) }
        reload()
        return created
    }

    func rename(_ collection: ClipCollection, to name: String) {
        attempt { try store.renameCollection(collection, to: name) }
        reload()
    }

    func delete(_ collection: ClipCollection) {
        attempt { try store.deleteCollection(collection) }
        reload()
    }

    func dismissReceipt() { receipt = nil }

    // MARK: Private

    /// The stored item behind an entry. For a capture this is a `files` item
    /// pointing at the capture, created on demand.
    private func clipItem(for entry: LibraryEntry, create: Bool) -> ClipItem? {
        switch entry {
        case .clip(let item):
            return item
        case .capture(let capture):
            // A capture in a collection is a reference to its file, not a copy.
            let candidate = ClipCandidate.files([capture.url])
            return create ? try? store.reference(candidate) : try? store.find(candidate)
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { problem = error.localizedDescription }
    }
}
