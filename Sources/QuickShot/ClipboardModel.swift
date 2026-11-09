import AppKit
import ClipboardCore
import Observation
import QuickShotCore

/// A place in the library's sidebar.
enum LibrarySection: Hashable {
    case history
    case screenshots
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

    /// - Parameter captures: QuickShot's captures, listed in place from their folder.
    init(
        store: ClipStore,
        pasteboard: NSPasteboard = .general,
        captures: @escaping () -> [CaptureItem],
        frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        accessDenied: (() -> Bool)? = nil
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.captures = captures
        monitor = ClipboardMonitor(
            pasteboard: pasteboard, store: store, frontmostApp: frontmostApp, accessDenied: accessDenied
        ) { [weak self] in
            guard let self else { return }
            self.monitorState = self.monitor.state
            self.reload()
        }
    }

    /// Clears expired history, loads the lists and starts recording copies.
    func start() {
        attempt { _ = try store.expire() }
        reload()
        monitor.start()
    }

    var entries: [LibraryEntry] {
        guard section == .screenshots else { return clips.map(LibraryEntry.clip) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return captures()
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map(LibraryEntry.capture)
    }

    var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selection }
    }

    var isPaused: Bool { monitorState == .paused }

    func reload() {
        attempt {
            collections = try store.collections()
            switch section {
            case .history: clips = try store.items(in: .history, matching: searchText)
            case .collection(let id): clips = try store.items(in: .collection(id), matching: searchText)
            case .screenshots: clips = []
            }
        }
        if case .collection(let id) = section, !collections.contains(where: { $0.id == id }) {
            section = .history
        }
    }

    func togglePause() {
        monitor.isPaused.toggle()
        monitorState = monitor.state
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
    func export(_ entry: LibraryEntry, to folder: URL) {
        attempt {
            let written: [URL]
            switch entry {
            case .clip(let item): written = try ClipExporter.export(item, from: store, to: folder)
            case .capture(let item): written = [try ClipExporter.copy(item.url, to: folder)]
            }
            guard let first = written.first else { return }
            let place = (folder.path as NSString).abbreviatingWithTildeInPath
            receipt = written.count == 1
                ? "Saved a copy as \(first.lastPathComponent) in \(place)."
                : "Saved \(written.count) copies in \(place)."
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
            let candidate = ClipCandidate.files([capture.url])
            if create { return try? store.record(candidate) }
            return (try? store.items(in: .history, matching: capture.url.lastPathComponent))?
                .first { $0.kind == .files && $0.text == capture.url.path }
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { problem = error.localizedDescription }
    }
}
