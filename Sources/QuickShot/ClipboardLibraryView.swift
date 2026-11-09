import AppKit
import ClipboardCore
import QuickShotCore
import SwiftUI

/// Sizes for the clipboard library window.
enum LibraryLayout {
    static let defaultSize = NSSize(width: 1020, height: 560)
    static let minimumSize = NSSize(width: 680, height: 360)
    /// Column widths: minimum, preferred, maximum. The detail pane takes the rest.
    static let sidebar = (min: CGFloat(140), ideal: CGFloat(170), max: CGFloat(200))
    static let list = (min: CGFloat(220), ideal: CGFloat(270), max: CGFloat(320))
    static let detailMinWidth: CGFloat = 300
    /// Long text is wrapped at this width so lines stay readable.
    static let readableWidth: CGFloat = 640
    static let thumbnail: CGFloat = 28
    /// Row thumbnails are decoded at this many pixels, once, then cached.
    static let thumbnailPixels = 96
}

/// Sidebar, list and detail pane for everything copied and captured.
struct ClipboardLibraryView: View {
    @Environment(ClipboardModel.self) private var model
    @State private var namingCollection = false
    @State private var renaming: ClipCollection?
    @State private var draftName = ""
    /// The entry waiting to join the collection being named, if any.
    @State private var pendingEntry: LibraryEntry?
    /// A status notice the person closed; it returns when the status changes.
    @State private var dismissedStatus: LibraryStatus?

    var body: some View {
        @Bindable var model = model
        // Three plain columns with draggable dividers. Everything sits below a
        // standard title bar; nothing depends on toolbar insets.
        HSplitView {
            sidebar
                .frame(minWidth: LibraryLayout.sidebar.min, idealWidth: LibraryLayout.sidebar.ideal, maxWidth: LibraryLayout.sidebar.max)
            VStack(spacing: 0) {
                SearchField(text: $model.searchText)
                notices
                entryList
            }
            .frame(minWidth: LibraryLayout.list.min, idealWidth: LibraryLayout.list.ideal, maxWidth: LibraryLayout.list.max)
            LibraryDetail(newCollection: nameCollection)
                .frame(minWidth: LibraryLayout.detailMinWidth, maxWidth: .infinity)
        }
        .frame(minWidth: LibraryLayout.minimumSize.width, minHeight: LibraryLayout.minimumSize.height)
        .onChange(of: model.status) { _, new in
            if new != dismissedStatus { dismissedStatus = nil }
        }
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

    /// Asks for a name; `entry`, if given, joins the new collection.
    private func nameCollection(for entry: LibraryEntry?) {
        pendingEntry = entry
        draftName = ""
        namingCollection = true
    }

    private var sidebar: some View {
        List(selection: Binding(get: { Optional(model.section) }, set: { if let new = $0 { model.section = new } })) {
            Section {
                Label("History", systemImage: "clock").tag(LibrarySection.history)
                // Screenshots and recordings alike, so the word is "Captures".
                Label("Captures", systemImage: "camera").tag(LibrarySection.captures)
            }
            .listRowSeparator(.hidden)
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
                Button("New Collection", systemImage: "plus") { nameCollection(for: nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.supportingText)
                    .accessibilityIdentifier("new-collection")
            }
            .listRowSeparator(.hidden)
        }
        // The inset style draws a plain selection that needs no window
        // material; a faint tone sets the sidebar apart from the list.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color.primary.opacity(Palette.tintOpacity / 2))
    }

    @ViewBuilder private var notices: some View {
        if let status = model.status, status != dismissedStatus {
            Banner(tone: status == .blocked ? .warning : .info, text: status.message,
                   actionTitle: status.actionTitle,
                   action: { status == .blocked ? CaptureActions.openPasteboardSettings() : model.togglePause() },
                   onDismiss: { dismissedStatus = status })
        }
        // With an item selected, problems show beside its actions instead.
        if model.selectedEntry == nil, let problem = model.problem {
            Banner(tone: .error, text: problem, onDismiss: { model.problem = nil })
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
                    .contextMenu { EntryActions(entry: entry, newCollection: nameCollection) }
            }
            .listStyle(.inset)
        }
    }

    private var emptyText: String {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return "Nothing matches \u{201C}\(query)\u{201D}." }
        switch model.section {
        case .history:
            // While copies are not being recorded, do not promise that they will appear.
            return model.status == nil
                ? "Nothing copied yet. Copy text, an image or a file in any app and it appears here."
                : "Nothing copied yet."
        case .captures: return "No captures yet. Press \(Shortcut.screenshot.words) to take a screenshot."
        case .collection: return "This collection is empty. Select an item in History and choose Add to Collection."
        }
    }
}

/// The search box above the list.
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true).foregroundStyle(Color.supportingText)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("library-search")
            if !text.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 24, minHeight: 24)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(Palette.tintOpacity / 2), in: RoundedRectangle(cornerRadius: Radius.thumbnail))
        .padding(Layout.padding)
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

/// One item: a small picture or symbol, the title on its own line, then what
/// it is and when.
struct EntryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 8) {
            EntryThumbnail(entry: entry)
                .frame(width: LibraryLayout.thumbnail, height: LibraryLayout.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
            // The title gets the full width; kind and time sit on a second
            // line so they never squeeze it.
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(entry.kindWord) · \(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.subheadline)
                    .foregroundStyle(Color.supportingText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            if let url = model.store.imageURL(for: item),
               let image = ThumbnailCache.image(for: url, maxPixels: LibraryLayout.thumbnailPixels) {
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

/// Small versions of stored images, decoded once. A stored image never
/// changes (its file is named by its content), so the cache never goes stale.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL, maxPixels: Int) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The selected item in full, with the actions that apply to it.
struct LibraryDetail: View {
    @Environment(ClipboardModel.self) private var model
    let newCollection: (LibraryEntry?) -> Void

    var body: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                // One line of facts; the content below is what matters.
                Text("\(entry.kindWord) · \(details(for: entry))")
                    .font(.subheadline)
                    .foregroundStyle(Color.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Layout.padding)
                Divider()
                content(for: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // What the last action did, beside the actions themselves.
                if let problem = model.problem {
                    Banner(tone: .error, text: problem, onDismiss: { model.problem = nil })
                } else if let receipt = model.receipt {
                    Banner(tone: .info, text: receipt, onDismiss: { model.dismissReceipt() })
                }
                Divider()
                // Actions sit at the bottom edge of the detail. Copy keeps its
                // name at every width; the rest fall back to symbols with tooltips.
                ViewThatFits(in: .horizontal) {
                    actionRow(for: entry, labels: .all)
                    actionRow(for: entry, labels: .copyOnly)
                    actionRow(for: entry, labels: .none)
                }
                .controlSize(.large)
                .padding(Layout.padding)
            }
        } else if !model.entries.isEmpty {
            Text("Select an item to see it here.")
                .foregroundStyle(Color.supportingText)
                .padding(Layout.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("library-no-selection")
        } else {
            // Nothing to select: say nothing.
            Color.clear
        }
    }

    private func actionRow(for entry: LibraryEntry, labels: EntryActions.Labels) -> some View {
        HStack(spacing: Layout.spacing) {
            EntryActions(entry: entry, newCollection: newCollection, labels: labels, inDetail: true)
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
                        .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
                        .padding(Layout.padding)
                        .accessibilityLabel(item.title)
                } else {
                    Text("The image file is missing.").padding(Layout.padding)
                }
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.filePaths, id: \.self) { path in
                            let missing = !FileManager.default.fileExists(atPath: path)
                            Text((path as NSString).abbreviatingWithTildeInPath + (missing ? " (moved or deleted)" : ""))
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
                .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
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
    /// Which buttons show their names.
    enum Labels {
        case all, copyOnly, none
    }

    @Environment(ClipboardModel.self) private var model
    let entry: LibraryEntry
    let newCollection: (LibraryEntry?) -> Void
    var labels: Labels = .all
    /// In the detail pane the actions carry keyboard shortcuts and Delete
    /// sits apart at the trailing edge; in a context menu they do neither.
    var inDetail = false
    @State private var confirmingDelete = false

    var body: some View {
        let copied = model.copiedEntry == entry.id
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            // Command C with words selected in the text or the search box
            // copies those words, as it does everywhere else.
            if inDetail, let words = TextSelection.selectedText() {
                model.copySelectedText(words)
            } else {
                model.copy(entry)
            }
        }
        .labelStyle(ToolbarOrMenuLabelStyle(iconOnly: labels == .none))
        .keyboardShortcut(inDetail ? KeyboardShortcut("c", modifiers: .command) : nil)
        .help("Copy to the clipboard")
        .accessibilityIdentifier("library-copy")

        Group {
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
            .help("Add to a collection, where items are kept until you remove them")
            .accessibilityIdentifier("library-collect")
            if let url = revealURL {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .help("Show in Finder")
            }
            if inDetail { Spacer(minLength: 0) }
            if case .clip = entry {
                Button("Delete", systemImage: "trash") {
                    if model.deletionRemovesSavedItem(entry) { confirmingDelete = true } else { model.delete(entry) }
                }
                .keyboardShortcut(inDetail ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                .help("Delete from history and from every collection")
                .accessibilityIdentifier("library-delete")
                .confirmationDialog("Delete this item from its collections too?", isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) { model.delete(entry) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("It is saved in a collection. Deleting removes it from history and from every collection.")
                }
            }
        }
        .labelStyle(ToolbarOrMenuLabelStyle(iconOnly: labels != .all))
    }

    /// The file to show in Finder: a capture, or the first file of a file item.
    private var revealURL: URL? {
        switch entry {
        case .capture(let item): item.url
        case .clip(let item): item.filePaths.first.map { URL(fileURLWithPath: $0) }
        }
    }
}

/// The words selected in the focused text, when there are any.
@MainActor
enum TextSelection {
    static func selectedText() -> String? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0, let text = textView.textStorage?.string else { return nil }
        return (text as NSString).substring(with: range)
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

/// What an entry carries when dragged into another app. A drag carries one
/// thing: the text, the image file, or the first file of a file item.
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
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clipboard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = LibraryLayout.minimumSize
        window.setContentSize(LibraryLayout.defaultSize)
        window.center()
        window.setFrameAutosaveName("QuickShotClipboard")
        return window
    }
}
