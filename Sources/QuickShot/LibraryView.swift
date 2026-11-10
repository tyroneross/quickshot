import QuickShotCore
import SwiftUI

/// Interface wording shared by the window, the menu and the tooltips.
enum Copy {
    static let permissionOff = "Screen Recording is off."
    static let permissionAsked = "Allow QuickShot in Settings, then reopen it."
    static let nothingSaved = "Nothing saved. The screenshot was cancelled or went to the clipboard."
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
    /// The strip holding the capture buttons. Fixed, so nothing below it
    /// moves when the buttons change to the capturing status.
    static let captureBarHeight: CGFloat = 100
    /// The "Saved in" line at the bottom.
    static let footerHeight: CGFloat = 28
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
    /// Label colour on a solid warning (amber) button.
    static let onWarning = Color.black
}

extension Color {
    static let supportingText = Color.primary.opacity(Palette.supportingTextOpacity)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            CaptureBar()
            // While a capture runs, the bar itself says what is happening.
            if model.activeCapture == nil, let notice = model.notice {
                NoticeBanner(notice: notice)
            }
            // With no captures the buttons are the whole screen: they already
            // say what to do, so nothing is written under them.
            if !model.items.isEmpty {
                CaptureGrid()
            }
            FolderFooter(directory: model.library.directory)
        }
        // The ideal size is what the content needs; the window follows it.
        .frame(minWidth: Layout.windowWidth, idealWidth: Layout.windowWidth, maxWidth: .infinity,
               maxHeight: .infinity, alignment: .top)
        .toolbar {
            // Present whenever there are captures, greyed out with nothing
            // selected: a title bar that appeared on selection would push
            // every card down. With no captures there is nothing to act on,
            // so the first screen is just the two buttons.
            if !model.items.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                    ItemActions(item: model.selectedItem, inToolbar: true)
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
            case .recording where model.isSavingRecording:
                CaptureStatus(title: "Saving the recording", hint: "Shrinking it to 1080p")
                Spacer(minLength: Layout.spacing)
            case .recording where model.countdown != nil:
                CaptureStatus(title: "Recording in \(model.countdown ?? 0)", hint: "\(model.recordingTarget.title), \(model.recordingPreset == .quick ? "Quick" : "Demo")")
                Spacer(minLength: Layout.spacing)
                Button("Cancel", systemImage: "xmark.circle") { model.cancelCapture() }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
                    .help("Do not start the recording")
                    .accessibilityIdentifier("cancel-capture")
            case .recording:
                Circle().fill(.red).frame(width: 10, height: 10).accessibilityHidden(true)
                CaptureStatus(title: "Recording", hint: "\(Shortcut.recording.words) also stops it")
                Spacer(minLength: Layout.spacing)
                Button("Stop Recording", systemImage: "stop.circle.fill") { model.stopRecording() }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
                    .help("Stop and save the recording (\(Shortcut.recording.words))")
                    .accessibilityIdentifier("stop-recording")
            case .area:
                CaptureStatus(title: "Choosing an area", hint: "Space picks a window. Escape cancels")
                Spacer(minLength: Layout.spacing)
                Button("Cancel", systemImage: "xmark.circle") { model.cancelCapture() }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
                    .help("Close the screenshot picker without saving")
                    .accessibilityIdentifier("cancel-capture")
            case .fullScreen:
                CaptureStatus(title: "Capturing the screen", hint: "Every display, in a moment")
                Spacer(minLength: Layout.spacing)
            case nil:
                CaptureTile(title: "Full Screen", symbol: "macwindow.on.rectangle", symbolColor: .primary, shortcut: .fullScreen,
                            help: "Capture every display at once (\(Shortcut.fullScreen.words))") {
                    model.capture(.fullScreen)
                }
                .accessibilityIdentifier("capture-full-screen")
                CaptureTile(title: "Area", symbol: "camera.viewfinder", symbolColor: .primary, shortcut: .area,
                            help: "Drag over an area with the mouse (\(Shortcut.area.words))") {
                    model.capture(.area)
                }
                .accessibilityIdentifier("capture-area")
                RecordMenu()
            }
        }
        .padding(Layout.padding)
        .frame(height: Layout.captureBarHeight)
    }
}

/// Where the captures live on this Mac. One click opens the folder.
struct FolderFooter: View {
    let directory: URL

    /// The path with the home folder shortened, as Finder's path bar reads.
    static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Label("Saved in \(Self.shortPath(directory))", systemImage: "folder")
                .font(.subheadline)
                .foregroundStyle(Color.supportingText)
                .lineLimit(1)
                .truncationMode(.middle)
            // The path reads as text; the button says it can be opened.
            Button("Open") { CaptureActions.openFolder(directory) }
                .controlSize(.small)
                .help("Open the captures folder in Finder")
                .accessibilityIdentifier("captures-folder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.padding)
        .frame(height: Layout.footerHeight)
    }
}

/// What is happening during a capture, with the one thing worth knowing.
struct CaptureStatus: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(Color.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("capture-status")
    }
}

/// The Record tile opens a menu: what to record, how, and whether to count
/// down. The shortcut repeats the last choice without the menu.
struct RecordMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            ForEach(RecordingTarget.allCases, id: \.self) { target in
                Button(target.title) { model.record(target) }
                    .keyboardShortcut(target == model.recordingTarget ? Shortcut.recording.keyboardShortcut : nil)
            }
            Divider()
            Picker("Recording Preset", selection: $model.recordingPreset) {
                ForEach(RecordingPreset.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Count Down \(AppModel.countdownSeconds) Seconds First", isOn: $model.countsDown)
        } label: {
            TileLabel(title: "Record", symbol: "record.circle", symbolColor: .red,
                      subtitle: model.recordingTarget.title, subtitleLabel: "\(model.recordingTarget.title), menu, \(Shortcut.recording.words)", isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(TileButtonStyle())
        .menuIndicator(.hidden)
        .help("Record the screen, an area, or one app (\(Shortcut.recording.words) repeats the last choice)")
        .accessibilityIdentifier("record-screen")
    }
}

/// One large capture button: a plain symbol, its name, and its shortcut as
/// key symbols.
struct CaptureTile: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    let shortcut: Shortcut
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TileLabel(title: title, symbol: symbol, symbolColor: symbolColor,
                      subtitle: shortcut.glyphs, subtitleLabel: shortcut.words)
        }
        .buttonStyle(TileButtonStyle())
        .help(help)
    }
}

struct TileLabel: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    let subtitle: String
    let subtitleLabel: String
    var isMenu = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.medium))
            HStack(spacing: 3) {
                Text(subtitle).lineLimit(1)
                if isMenu { Image(systemName: "chevron.down").font(.caption2) }
            }
            .font(.subheadline)
            .foregroundStyle(Color.supportingText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(subtitleLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
/// symbols with tooltips so the window can stay narrow, and they stay in place
/// (greyed out) with nothing selected; in the context menu the same actions
/// carry their names.
struct ItemActions: View {
    @Environment(AppModel.self) private var model
    let item: CaptureItem?
    var inToolbar = false

    var body: some View {
        let copied = item != nil && model.copiedItem == item?.id
        let isVideo = item?.kind == .video
        Group {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                if let item { model.copy(item) }
            }
            .keyboardShortcut(inToolbar ? KeyboardShortcut("c", modifiers: .command) : nil)
            .help(copied ? "Copied" : "Copy to the clipboard")
            .accessibilityIdentifier("copy-capture")
            Button(isVideo ? "Open" : "Annotate", systemImage: isVideo ? "play.rectangle" : "rectangle.badge.plus") {
                if let item { model.annotate(item) }
            }
            .keyboardShortcut(inToolbar ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help(isVideo ? "Open in QuickTime Player" : "Draw boxes around content, then copy the marked picture")
            .accessibilityIdentifier("open-capture")
            if !inToolbar, !isVideo {
                // Preview's Markup still has arrows and text.
                Button("Open in Preview", systemImage: "pencil.tip.crop.circle") {
                    if let item { CaptureActions.open(item) }
                }
                .accessibilityIdentifier("open-in-preview")
            }
            Button("Show in Finder", systemImage: "folder") {
                if let item { CaptureActions.reveal(item) }
            }
            .help("Show in Finder")
            .accessibilityIdentifier("reveal-capture")
            Button("Move to Trash", systemImage: "trash") {
                if let item { model.trash(item) }
            }
            .keyboardShortcut(inToolbar ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .help("Move to Trash")
            .accessibilityIdentifier("trash-capture")
        }
        .labelStyle(ToolbarOrMenuLabelStyle(iconOnly: inToolbar))
        .disabled(item == nil)
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
    /// With seconds: a capture and its marked copy are often a minute apart.
    private var time: String {
        item.created.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
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
                    if item.isMarked {
                        // A marked copy sits beside its original with the same minute.
                        Text("Marked")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(Palette.tintOpacity), in: Capsule())
                    }
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
            model.annotate(item)
        })
        .draggable(item.url)
        .contextMenu { ItemActions(item: item) }
        .help("\(kindWord): \(item.url.lastPathComponent)")
        .accessibilityLabel("\(item.isMarked ? "Marked screenshot" : kindWord), \(time)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("capture-card")
    }
}

struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: AppModel.Notice

    var body: some View {
        switch notice {
        case .permissionNeeded:
            // Two short steps instead of one paragraph: turn it on, then reopen.
            if model.askedForAccess {
                // Settings stays reachable: the request may have been refused
                // or left unfinished.
                Banner(tone: .warning, text: Copy.permissionAsked,
                       actionTitle: "Reopen QuickShot", action: { model.reopen() },
                       secondaryTitle: "Settings", secondaryAction: CaptureActions.openScreenRecordingSettings,
                       onDismiss: { model.notice = nil })
            } else {
                Banner(tone: .warning, text: Copy.permissionOff,
                       actionTitle: "Turn On",
                       action: {
                           model.requestScreenAccess()
                           CaptureActions.openScreenRecordingSettings()
                       },
                       onDismiss: { model.notice = nil })
            }
        case .nothingSaved:
            Banner(tone: .info, text: Copy.nothingSaved, onDismiss: { model.notice = nil })
        case .problem(let message, let retry):
            Banner(tone: .error, text: message,
                   actionTitle: retry == nil ? nil : "Try Again", action: retry?.action,
                   onDismiss: { model.notice = nil })
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
    /// A second, quieter action beside the main one.
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    @Environment(\.controlActiveState) private var controlActiveState

    private var message: some View {
        Text(text).accessibilityLabel("\(tone.word). \(text)")
    }

    @ViewBuilder private var actionButton: some View {
        HStack(spacing: 8) {
            mainActionButton
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .accessibilityIdentifier("notice-secondary-action")
            }
        }
    }

    @ViewBuilder private var mainActionButton: some View {
        if let actionTitle, let action {
            // A warning's action takes the warning's colour. Black on amber is
            // measured in ContrastTests; white would fail.
            if tone == .warning {
                // In a window that is not key AppKit drops the amber fill, so a
                // black label would sit on the plain bezel (measured 1.96:1 in
                // dark). The label follows the fill.
                Button(action: action) { Text(actionTitle).foregroundStyle(controlActiveState == .key ? Palette.onWarning : Color.primary) }
                    .buttonStyle(.borderedProminent)
                    .tint(tone.color)
                    .accessibilityIdentifier("notice-action")
            } else {
                Button(actionTitle, action: action)
                    .accessibilityIdentifier("notice-action")
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.spacing) {
            // A short message and its action share one row; a long message
            // takes the full width with the action under it, in reading order.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Layout.spacing) {
                    message.lineLimit(1).fixedSize()
                    actionButton
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    message.fixedSize(horizontal: false, vertical: true)
                    actionButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .padding(.leading, Layout.padding)
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
