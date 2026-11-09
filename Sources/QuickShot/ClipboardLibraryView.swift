import AppKit
import ClipboardCore
import QuickShotCore
import SwiftUI

/// Sizes for the clipboard library window.
enum LibraryLayout {
    static let defaultSize = NSSize(width: 860, height: 520)
    static let minimumSize = NSSize(width: 640, height: 360)
    static let sidebarWidth: CGFloat = 170
    static let listWidth: CGFloat = 260
    /// Long text is wrapped at this width so lines stay readable.
    static let readableWidth: CGFloat = 640
    static let thumbnail: CGFloat = 28
}

/// Sidebar, list and detail pane for everything copied and captured.
struct ClipboardLibraryView: View {
    @Environment(ClipboardModel.self) private var model
    @State private var namingCollection = false
    @State private var renaming: ClipCollection?
    @State private var draftName = ""
    /// The entry waiting to join the collection being named, if any.
    @State private var pendingEntry: LibraryEntry?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 140, ideal: LibraryLayout.sidebarWidth, max: 240)
        } content: {
            VStack(spacing: 0) {
                notices
                entryList
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: LibraryLayout.listWidth, max: 420)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        } detail: {
            LibraryDetail(newCollection: { entry in
                pendingEntry = entry
                draftName = ""
                namingCollection = true
            })
        }
        .frame(minWidth: LibraryLayout.minimumSize.width, minHeight: LibraryLayout.minimumSize.height)
        .alert("New Collection", isPresented: $namingCollection) {
            TextField("Name", text: $draftName)
            Button("Create") {
                if let created = model.createCollection(named: draftName) {
                    if let pendingEntry { model.add(pendingEntry, to: created) } else { model.section = .collection(created.id) }
                }
                pendingEntry = nil
            }
            Button("Cancel", role: .cancel) { pendingEntry = nil }
        } message: {
            Text("Items in a collection are kept until you remove them.")
        }
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renaming { model.rename(renaming, to: draftName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { Optional(model.section) }, set: { if let new = $0 { model.section = new } })) {
            Section {
                Label("History", systemImage: "clock").tag(LibrarySection.history)
                Label("Screenshots", systemImage: "camera").tag(LibrarySection.screenshots)
            }
            Section("Collections") {
                ForEach(model.collections) { collection in
                    Label(collection.name, systemImage: "folder")
                        .tag(LibrarySection.collection(collection.id))
                        .contextMenu {
                            Button("Rename") {
                                draftName = collection.name
                                renaming = collection
                            }
                            Button("Delete Collection") { model.delete(collection) }
                        }
                }
                Button("New Collection", systemImage: "plus") {
                    pendingEntry = nil
                    draftName = ""
                    namingCollection = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.supportingText)
                .accessibilityIdentifier("new-collection")
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var notices: some View {
        if model.monitorState == .blocked {
            Banner(tone: .warning,
                   text: "macOS is set to deny QuickShot the clipboard, so new copies are not recorded. Allow it under Paste from Other Apps.",
                   actionTitle: "Open Settings", action: CaptureActions.openPasteboardSettings)
        } else if model.isPaused {
            Banner(tone: .info, text: "Clipboard history is paused. New copies are not recorded.",
                   actionTitle: "Resume", action: { model.togglePause() })
        }
        if let problem = model.problem {
            Banner(tone: .error, text: problem, onDismiss: { model.problem = nil })
        } else if let receipt = model.receipt {
            Banner(tone: .info, text: receipt, onDismiss: { model.dismissReceipt() })
        }
    }

    @ViewBuilder private var entryList: some View {
        @Bindable var model = model
        let entries = model.entries
        if entries.isEmpty {
            EmptyLibraryHint(text: emptyText)
        } else {
            List(entries, selection: $model.selection) { entry in
                EntryRow(entry: entry)
                    .tag(entry.id)
                    .onDrag { DragPayload.provider(for: entry, store: model.store) }
                    .contextMenu { EntryActions(entry: entry, newCollection: { pendingEntry = $0; draftName = ""; namingCollection = true }) }
            }
            .listStyle(.inset)
        }
    }

    private var emptyText: String {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return "Nothing matches \u{201C}\(query)\u{201D}." }
        switch model.section {
        case .history: return "Nothing copied yet. Copy text, an image or a file in any app and it appears here."
        case .screenshots: return "No captures yet. Press \(Shortcut.screenshot.words) to take a screenshot."
        case .collection: return "This collection is empty. Select an item in History and choose Add to Collection."
        }
    }
}

struct EmptyLibraryHint: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Color.supportingText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Layout.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("library-empty")
    }
}

/// One line per item: a small picture or symbol, the title, and the time.
struct EntryRow: View {
    @Environment(ClipboardModel.self) private var model
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 8) {
            EntryThumbnail(entry: entry)
                .frame(width: LibraryLayout.thumbnail, height: LibraryLayout.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
            Text(entry.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.subheadline)
                .foregroundStyle(Color.supportingText)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kindWord): \(entry.title)")
    }
}

struct EntryThumbnail: View {
    @Environment(ClipboardModel.self) private var model
    let entry: LibraryEntry

    var body: some View {
        switch entry {
        case .clip(let item):
            if let url = model.store.imageURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                symbol
            }
        case .capture(let item):
            ThumbnailView(item: item)
        }
    }

    private var symbol: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: entry.symbol).accessibilityHidden(true).foregroundStyle(Color.supportingText)
        }
    }
}

/// The selected item in full, with the actions that apply to it.
struct LibraryDetail: View {
    @Environment(ClipboardModel.self) private var model
    let newCollection: (LibraryEntry) -> Void

    var body: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.kindWord).font(.headline)
                    Text(details(for: entry))
                        .font(.subheadline)
                        .foregroundStyle(Color.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Layout.padding)
                Divider()
                content(for: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                // Actions for the detail sit at its bottom edge.
                HStack(spacing: Layout.spacing) {
                    EntryActions(entry: entry, newCollection: newCollection)
                    Spacer(minLength: 0)
                }
                .padding(Layout.padding)
            }
        } else {
            Text("Select an item to see it here.")
                .foregroundStyle(Color.supportingText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("library-no-selection")
        }
    }

    @ViewBuilder private func content(for entry: LibraryEntry) -> some View {
        switch entry {
        case .clip(let item):
            switch item.kind {
            case .text:
                ScrollView {
                    Text(item.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: LibraryLayout.readableWidth, alignment: .leading)
                        .padding(Layout.padding)
                }
            case .image:
                if let url = model.store.imageURL(for: item), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(Layout.padding)
                        .accessibilityLabel(item.title)
                } else {
                    Text("The image file is missing.").padding(Layout.padding)
                }
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.filePaths, id: \.self) { path in
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: LibraryLayout.readableWidth, alignment: .leading)
                    .padding(Layout.padding)
                }
            }
        case .capture(let item):
            ThumbnailView(item: item)
                .aspectRatio(contentMode: .fit)
                .padding(Layout.padding)
        }
    }

    private func details(for entry: LibraryEntry) -> String {
        let time = entry.date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        switch entry {
        case .clip(let item):
            var parts = ["Copied \(time)", ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)]
            if let app = item.sourceApp { parts.append("from \(AppNames.name(for: app))") }
            return parts.joined(separator: " · ")
        case .capture(let item):
            return ["Captured \(time)", ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file),
                    item.url.lastPathComponent].joined(separator: " · ")
        }
    }
}

/// What can be done with one entry. Only the actions that apply are shown.
struct EntryActions: View {
    @Environment(ClipboardModel.self) private var model
    let entry: LibraryEntry
    let newCollection: (LibraryEntry) -> Void

    var body: some View {
        let copied = model.copiedEntry == entry.id
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { model.copy(entry) }
            .keyboardShortcut("c", modifiers: .command)
            .accessibilityIdentifier("library-copy")
        Button("Save to Folder…", systemImage: "square.and.arrow.down") {
            if let folder = FolderPicker.choose() { model.export(entry, to: folder) }
        }
        .help("Save a copy in a folder. The item stays here.")
        .accessibilityIdentifier("library-export")
        Menu("Add to Collection", systemImage: "folder.badge.plus") {
            let held = model.collectionIDs(for: entry)
            ForEach(model.collections) { collection in
                if held.contains(collection.id) {
                    Button("Remove from \(collection.name)", systemImage: "checkmark") { model.remove(entry, from: collection) }
                } else {
                    Button(collection.name) { model.add(entry, to: collection) }
                }
            }
            if !model.collections.isEmpty { Divider() }
            Button("New Collection…") { newCollection(entry) }
        }
        .fixedSize()
        .accessibilityIdentifier("library-collect")
        switch entry {
        case .clip(let item):
            if item.kind == .files, let first = item.filePaths.first {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                }
            }
            Button("Delete", systemImage: "trash") { model.delete(entry) }
                .help("Remove from history and from every collection")
                .accessibilityIdentifier("library-delete")
        case .capture(let item):
            Button("Show in Finder", systemImage: "folder") { CaptureActions.reveal(item) }
        }
    }
}

/// Asks for a folder with the system panel.
@MainActor
enum FolderPicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the copy."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// What an entry carries when dragged into another app.
@MainActor
enum DragPayload {
    static func provider(for entry: LibraryEntry, store: ClipStore) -> NSItemProvider {
        switch entry {
        case .clip(let item):
            switch item.kind {
            case .text:
                return NSItemProvider(object: item.text as NSString)
            case .image:
                return store.imageURL(for: item).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
            case .files:
                return item.filePaths.first.flatMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) } ?? NSItemProvider()
            }
        case .capture(let item):
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
    }
}

/// Display names for apps, from their bundle identifiers.
@MainActor
enum AppNames {
    static func name(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Builds the clipboard library window.
@MainActor
enum ClipboardWindow {
    static func make(model: ClipboardModel) -> NSWindow {
        let hosting = NSHostingController(rootView: ClipboardLibraryView().environment(model))
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clipboard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = LibraryLayout.minimumSize
        window.setContentSize(LibraryLayout.defaultSize)
        window.center()
        window.setFrameAutosaveName("QuickShotClipboard")
        return window
    }
}
