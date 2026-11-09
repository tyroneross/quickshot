import AppKit

/// Watches a pasteboard and records each new copy.
///
/// macOS has no "clipboard changed" event, so the monitor reads the change
/// counter on a timer. A tick that finds the counter unchanged does nothing else.
@MainActor
public final class ClipboardMonitor {
    public enum State: Sendable, Equatable {
        case running
        case paused
        /// macOS is set to deny this app the clipboard ("Paste from Other Apps").
        case blocked
    }

    public static let interval: TimeInterval = 0.5

    public private(set) var state: State = .running
    private let pasteboard: NSPasteboard
    private let store: ClipStore
    private let frontmostApp: () -> String?
    private let accessDenied: () -> Bool
    private let onChange: () -> Void
    private var lastChangeCount: Int
    private var timer: Timer?

    /// - Parameters:
    ///   - frontmostApp: bundle identifier of the app in front, used as the
    ///     source of a copy. A copy made by a background app is attributed to
    ///     whatever is in front.
    ///   - accessDenied: whether macOS denies this app the clipboard.
    ///   - onChange: called after an item is recorded or the state changes.
    public init(
        pasteboard: NSPasteboard = .general,
        store: ClipStore,
        frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        accessDenied: (() -> Bool)? = nil,
        onChange: @escaping () -> Void
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.frontmostApp = frontmostApp
        self.accessDenied = accessDenied ?? { Self.systemDenies(pasteboard) }
        self.onChange = onChange
        // What was copied before launch is not history.
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public var isPaused: Bool {
        get { state == .paused }
        set {
            guard newValue != isPaused else { return }
            // Copies made while paused are not picked up afterwards.
            lastChangeCount = pasteboard.changeCount
            setState(newValue ? .paused : .running)
        }
    }

    /// One check of the pasteboard. The timer calls this; tests call it directly.
    public func tick() {
        guard state != .paused else { return }
        if accessDenied() {
            setState(.blocked)
            return
        }
        setState(.running)
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard case .item(let candidate) = ClipboardReader.read(pasteboard, sourceApp: frontmostApp()) else { return }
        if (try? store.record(candidate)) != nil { onChange() }
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onChange()
    }

    private static func systemDenies(_ pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysDeny }
        return false
    }
}
