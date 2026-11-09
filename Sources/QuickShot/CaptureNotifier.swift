import AppKit
import QuickShotCore
import UserNotifications

/// Tells the person a capture was saved, as a system notification with the
/// picture in it, so the window need not come forward. Clicking the
/// notification shows the capture in QuickShot.
@MainActor
final class CaptureNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "capture-saved"
    nonisolated static let itemKey = "item"

    private let center: UNUserNotificationCenter?
    private var asked = false
    /// Opens the library with the named capture selected.
    var open: (CaptureItem.ID) -> Void = { _ in }

    /// `nil` outside an app bundle (tests), where the notification center
    /// cannot be used.
    override init() {
        center = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
            ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    /// Returns `false` when the person will not see a notification (not
    /// allowed, or the system refused it), so the caller can show the window
    /// instead: a saved capture always gives a signal.
    func notify(_ item: CaptureItem, copied: Bool) async -> Bool {
        guard let center else { return false }
        if !asked {
            asked = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        // Allowed is not enough: a notification with banners turned off would
        // arrive silently, which is no signal at all.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized, settings.alertSetting == .enabled, settings.alertStyle != .none else { return false }
        let content = UNMutableNotificationContent()
        content.title = item.kind == .image ? "Screenshot saved" : "Recording saved"
        content.body = copied
            ? "On the clipboard and in QuickShot. Click to see it."
            : "\(item.url.lastPathComponent) is in QuickShot. Click to see it."
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.itemKey: item.id]
        let copy = Self.attachmentCopy(for: item)
        if let copy, let attachment = try? UNNotificationAttachment(identifier: item.id, url: copy) {
            content.attachments = [attachment]
        }
        do {
            try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        } catch {
            // The system took the attachment, or never did; either way the copy
            // is not wanted any more.
            if let copy { try? FileManager.default.removeItem(at: copy) }
            return false
        }
        if let copy { try? FileManager.default.removeItem(at: copy) }
        return true
    }

    /// What the system accepts as a notification attachment (Apple's limits:
    /// 10 MB for an image, 50 MB for a movie).
    static func attachmentLimit(for kind: CaptureKind) -> Int {
        switch kind {
        case .image: 10 * 1024 * 1024
        case .video: 50 * 1024 * 1024
        }
    }

    /// The system moves an attachment into its own store, so it gets a copy,
    /// never the capture itself; and no copy at all when it would be refused.
    private static func attachmentCopy(for item: CaptureItem) -> URL? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.size] as? Int,
              size <= attachmentLimit(for: item.kind) else { return nil }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShot-notification-\(UUID().uuidString)")
            .appendingPathExtension(item.url.pathExtension)
        guard (try? FileManager.default.copyItem(at: item.url, to: copy)) != nil else { return nil }
        return copy
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo[Self.itemKey] as? String else { return }
        await MainActor.run { open(id) }
    }
}
