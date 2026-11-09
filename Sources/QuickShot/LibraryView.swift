import QuickShotCore
import SwiftUI

/// Interface wording shared by the window, the menu and the tooltips.
enum Copy {
    static let choosing = "Drag to choose an area, or press Space to pick a window. Escape cancels."
    static let recording = "Recording the screen. Stop it here, from the QuickShot menu bar item, or by pressing \(Shortcut.recording.words)."
    static let permission = "QuickShot needs Screen Recording permission before it can capture. Turn it on in System Settings, then quit and reopen QuickShot."
    static let nothingSaved = "Nothing was saved. The capture was cancelled, or sent to the clipboard by holding Control."
}

/// Corner radii, one family.
enum Radius {
    static let thumbnail: CGFloat = 6
    static let card: CGFloat = 8
}

/// Sizes that shape the window. The window takes its size from the content,
/// so these decide how small it can be and when the grid starts to scroll.
enum Layout {
    /// The narrowest and the default window width: two cards side by side.
    static let windowWidth: CGFloat = 340
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 10
    /// The strip holding the two capture buttons. Fixed, so nothing below it
    /// moves when the buttons change to the capturing status.
    static let captureBarHeight: CGFloat = 88
    static let cardMinWidth: CGFloat = 140
    /// The grid grows with its content up to about two rows, then scrolls.
    static let gridMaxIdealHeight: CGFloat = 330
}

/// The few colour strengths the interface uses, in one place so the contrast
/// tests measure the same values the views draw.
enum Palette {
    /// Supporting text is the label colour at this strength. System secondary
    /// text falls below 4.5:1 on a window background.
    static let supportingTextOpacity = 0.72
    /// Selection and banner backgrounds are a colour at this strength.
    static let tintOpacity = 0.12
}

extension Color {
    static let supportingText = Color.primary.opacity(Palette.supportingTextOpacity)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            CaptureBar()
            if let active = model.activeCapture {
                Banner(tone: .info, text: active == .recording ? Copy.recording : Copy.choosing)
            } else if let notice = model.notice {
                NoticeBanner(notice: notice)
            }
            if model.items.isEmpty {
                EmptyHint()
            } else {
                CaptureGrid()
            }
        }
        // The ideal size is what the content needs; the window follows it.
        .frame(minWidth: Layout.windowWidth, idealWidth: Layout.windowWidth, maxWidth: .infinity,
               maxHeight: .infinity, alignment: .top)
        .toolbar {
            if let item = model.selectedItem {
                ToolbarItemGroup(placement: .primaryAction) {
                    ItemActions(item: item, inToolbar: true)
                }
            }
        }
    }
}

/// The two capture buttons, or the capturing status with its way out.
struct CaptureBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Layout.spacing) {
            switch model.activeCapture {
            case .recording:
                Circle().fill(.red).frame(width: 10, height: 10).accessibilityHidden(true)
                Text("Recording")
                    .font(.headline)
                    .accessibilityIdentifier("capture-status")
                Spacer(minLength: Layout.spacing)
                Button("Stop Recording", systemImage: "stop.circle.fill") { model.stopRecording() }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
                    .help("Stop and save the recording (\(Shortcut.recording.words))")
                    .accessibilityIdentifier("stop-recording")
            case .screenshot:
                Text("Choosing an area")
                    .font(.headline)
                    .accessibilityIdentifier("capture-status")
                Spacer(minLength: Layout.spacing)
                Button("Cancel", systemImage: "xmark.circle") { model.cancelCapture() }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
                    .help("Close the screenshot picker without saving")
                    .accessibilityIdentifier("cancel-capture")
            case nil:
                CaptureTile(title: "Screenshot", symbol: "camera.fill", symbolColor: .primary,
                            help: "Take a screenshot (\(Shortcut.screenshot.words))") {
                    model.capture(.screenshot)
                }
                .accessibilityIdentifier("take-screenshot")
                CaptureTile(title: "Record", symbol: "record.circle", symbolColor: .red,
                            help: "Record the screen (\(Shortcut.recording.words))") {
                    model.capture(.recording)
                }
                .accessibilityIdentifier("record-screen")
            }
        }
        .padding(Layout.padding)
        .frame(height: Layout.captureBarHeight)
    }
}

/// One large capture button: a plain symbol above its name.
struct CaptureTile: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TileButtonStyle())
        .help(help)
    }
}

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? Palette.tintOpacity : Palette.tintOpacity / 2),
                        in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.primary.opacity(0.15))
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
    }
}

/// The four things to do with one capture. In the title bar they are plain
/// symbols with tooltips so the window can stay narrow; in the context menu
/// the same actions carry their names.
struct ItemActions: View {
    @Environment(AppModel.self) private var model
    let item: CaptureItem
    var inToolbar = false

    var body: some View {
        let copied = model.copiedItem == item.id
        Group {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { model.copy(item) }
                .keyboardShortcut(inToolbar ? KeyboardShortcut("c", modifiers: .command) : nil)
                .help("Copy to the clipboard")
                .accessibilityIdentifier("copy-capture")
            Button(item.kind == .image ? "Annotate" : "Open",
                   systemImage: item.kind == .image ? "pencil.tip.crop.circle" : "play.rectangle") {
                CaptureActions.open(item)
            }
            .keyboardShortcut(inToolbar ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help(item.kind == .image ? "Annotate in Preview" : "Open in QuickTime Player")
            .accessibilityIdentifier("open-capture")
            Button("Show in Finder", systemImage: "folder") { CaptureActions.reveal(item) }
                .help("Show in Finder")
                .accessibilityIdentifier("reveal-capture")
            Button("Move to Trash", systemImage: "trash") { model.trash(item) }
                .keyboardShortcut(inToolbar ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                .help("Move to Trash")
                .accessibilityIdentifier("trash-capture")
        }
        .labelStyle(ToolbarOrMenuLabelStyle(iconOnly: inToolbar))
    }
}

/// Symbol only in the title bar, name and symbol in menus.
struct ToolbarOrMenuLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        // Both branches keep the title: `.iconOnly` hides it visually but it
        // remains the button's accessible name.
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

struct CaptureGrid: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0
    private let columns = [GridItem(.adaptive(minimum: Layout.cardMinWidth), spacing: Layout.spacing)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Layout.spacing) {
                ForEach(model.items) { item in
                    CaptureCard(item: item, isSelected: model.selection == item.id)
                }
            }
            .padding([.horizontal, .bottom], Layout.padding)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // Ask for exactly what the captures need, up to the scroll limit.
        .frame(idealHeight: min(contentHeight, Layout.gridMaxIdealHeight), maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = nil }
    }
}

struct CaptureCard: View {
    @Environment(AppModel.self) private var model
    let item: CaptureItem
    let isSelected: Bool

    private var kindWord: String { item.kind == .image ? "Screenshot" : "Recording" }
    private var time: String {
        item.created.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        Button {
            model.selection = item.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ThumbnailView(item: item)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            // Decorative: the card's selected trait says the same.
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        }
                    }
                HStack(spacing: 4) {
                    if item.kind == .video {
                        // Marks a recording without relying on the thumbnail.
                        Image(systemName: "video.fill").accessibilityHidden(true)
                    }
                    Text(time)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.subheadline)
                .foregroundStyle(Color.supportingText)
            }
            .padding(8)
            .background(
                isSelected ? Color.accentColor.opacity(Palette.tintOpacity) : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selection = item.id
            CaptureActions.open(item)
        })
        .draggable(item.url)
        .contextMenu { ItemActions(item: item) }
        .help("\(kindWord): \(item.url.lastPathComponent)")
        .accessibilityLabel("\(kindWord), \(time)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("capture-card")
    }
}

/// Shown until the first capture exists: what is missing and how to start.
/// The two capture buttons sit directly above, so this stays to two lines.
struct EmptyHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No captures yet. In any app, press \(Shortcut.screenshot.words) for a screenshot or \(Shortcut.recording.words) to record.")
            Text("Captures are saved to \((model.library.directory.path as NSString).abbreviatingWithTildeInPath).")
                .font(.subheadline)
                .foregroundStyle(Color.supportingText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .bottom], Layout.padding)
        .accessibilityIdentifier("empty-hint")
    }
}

struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: AppModel.Notice

    var body: some View {
        switch notice {
        case .permissionNeeded:
            Banner(tone: .warning, text: Copy.permission,
                   actionTitle: "Open Settings", action: CaptureActions.openScreenRecordingSettings,
                   onDismiss: { model.notice = nil })
        case .nothingSaved:
            Banner(tone: .info, text: Copy.nothingSaved, onDismiss: { model.notice = nil })
        case .problem(let message):
            Banner(tone: .error, text: message, onDismiss: { model.notice = nil })
        }
    }
}

/// A tinted strip with a coloured leading edge. The tone is carried by the
/// edge and the wording, never by colour alone.
struct Banner: View {
    enum Tone: CaseIterable {
        case info, warning, error

        var color: Color {
            switch self {
            case .info: .accentColor
            case .warning: .orange
            case .error: .red
            }
        }

        var word: String {
            switch self {
            case .info: "Note"
            case .warning: "Action needed"
            case .error: "Error"
            }
        }
    }

    let tone: Tone
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Layout.spacing) {
            // The action sits under the message, in reading order, so the
            // message keeps the full width instead of wrapping beside a button.
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(tone.word). \(text)")
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .accessibilityIdentifier("notice-action")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
                    .help("Dismiss")
                    .accessibilityIdentifier("notice-dismiss")
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, Layout.padding + 4)
        .padding(.trailing, Layout.padding)
        .background(tone.color.opacity(Palette.tintOpacity))
        .overlay(alignment: .leading) {
            Rectangle().fill(tone.color).frame(width: 3)
        }
        // Space before whatever follows the notice.
        .padding(.bottom, Layout.padding)
        .accessibilityIdentifier("notice")
    }
}
