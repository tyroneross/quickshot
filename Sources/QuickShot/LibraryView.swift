import QuickShotCore
import SwiftUI

/// Interface wording shared by the window, the menu and the tooltips.
enum Copy {
    static let capturing = "Capture in progress. Finish in the system toolbar, or press Escape to cancel. To end a recording, use the Stop button in the menu bar."
    static let permission = "QuickShot needs Screen Recording permission before it can capture. Turn it on in System Settings, then quit and reopen QuickShot."
    static let nothingSaved = "Nothing was saved. The capture was cancelled, copied to the clipboard, or saved to another location from the toolbar."
}

/// Corner radii, one family.
enum Radius {
    static let thumbnail: CGFloat = 6
    static let card: CGFloat = 8
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
            if model.isCapturing {
                Banner(tone: .info, text: Copy.capturing)
            } else if let notice = model.notice {
                NoticeBanner(notice: notice)
            }
            if model.items.isEmpty {
                EmptyLibraryView()
            } else {
                CaptureGrid()
            }
        }
        .frame(minWidth: LibraryWindow.minimumContentSize.width, minHeight: LibraryWindow.minimumContentSize.height)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                CaptureControls()
            }
            if let item = model.selectedItem {
                ToolbarItemGroup(placement: .primaryAction) {
                    ItemActions(item: item, shortcuts: true)
                }
            }
        }
    }
}

/// Screenshot and Record, or the capturing status with its way out.
struct CaptureControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isCapturing {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("Capturing")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture-status")
            Button("Cancel Capture", systemImage: "xmark.circle") { model.cancelCapture() }
                .labelStyle(.titleAndIcon)
                .help("Close the system picker without saving")
                .accessibilityIdentifier("cancel-capture")
        } else {
            Button("Screenshot", systemImage: "camera.viewfinder") { model.capture(.screenshot) }
                .labelStyle(.titleAndIcon)
                .help("Take a screenshot (\(Shortcut.screenshot.words))")
                .accessibilityIdentifier("take-screenshot")
            Button("Record", systemImage: "record.circle") { model.capture(.recording) }
                .labelStyle(.titleAndIcon)
                .help("Record the screen (\(Shortcut.recording.words))")
                .accessibilityIdentifier("record-screen")
        }
    }
}

/// The four things to do with one capture. Used by the toolbar and by the
/// context menu so both always offer the same actions.
struct ItemActions: View {
    @Environment(AppModel.self) private var model
    let item: CaptureItem
    var shortcuts = false

    var body: some View {
        let copied = model.copiedItem == item.id
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { model.copy(item) }
            .labelStyle(.titleAndIcon)
            .keyboardShortcut(shortcuts ? KeyboardShortcut("c", modifiers: .command) : nil)
            .help("Copy to the clipboard")
            .accessibilityIdentifier("copy-capture")
        Button(item.kind == .image ? "Annotate" : "Open",
               systemImage: item.kind == .image ? "pencil.tip.crop.circle" : "play.rectangle") {
            CaptureActions.open(item)
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut(shortcuts ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .help(item.kind == .image ? "Open in Preview to annotate" : "Open in QuickTime Player")
        .accessibilityIdentifier("open-capture")
        Button("Show in Finder", systemImage: "folder") { CaptureActions.reveal(item) }
            .labelStyle(.titleAndIcon)
            .help("Show the file in Finder")
            .accessibilityIdentifier("reveal-capture")
        Button("Move to Trash", systemImage: "trash") { model.trash(item) }
            .labelStyle(.titleAndIcon)
            .keyboardShortcut(shortcuts ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .help("Move to the Trash. Put it back from the Trash in Finder.")
            .accessibilityIdentifier("trash-capture")
    }
}

struct CaptureGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.items) { item in
                    CaptureCard(item: item, isSelected: model.selection == item.id)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
        }
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
                Text("\(kindWord) · \(time)")
                    .font(.subheadline)
                    .foregroundStyle(Color.supportingText)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .help(item.url.lastPathComponent)
        .accessibilityLabel("\(kindWord), \(time)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("capture-card")
    }
}

/// Shown until the first capture exists: what is missing and how to start.
struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text("No captures yet")
                .font(.title3.weight(.semibold))
            if !model.isCapturing {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Button("Screenshot", systemImage: "camera.viewfinder") { model.capture(.screenshot) }
                            .accessibilityIdentifier("empty-take-screenshot")
                        Text("or press \(Shortcut.screenshot.words) in any app")
                    }
                    GridRow {
                        Button("Record", systemImage: "record.circle") { model.capture(.recording) }
                            .accessibilityIdentifier("empty-record-screen")
                        Text("or press \(Shortcut.recording.words) in any app")
                    }
                }
                .controlSize(.large)
            }
            Text("Captures are saved to \((model.library.directory.path as NSString).abbreviatingWithTildeInPath).")
                .font(.subheadline)
                .foregroundStyle(Color.supportingText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(alignment: .center, spacing: 12) {
            Text(text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(tone.word). \(text)")
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityIdentifier("notice-action")
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
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .background(tone.color.opacity(Palette.tintOpacity))
        .overlay(alignment: .leading) {
            Rectangle().fill(tone.color).frame(width: 3)
        }
        .accessibilityIdentifier("notice")
    }
}
