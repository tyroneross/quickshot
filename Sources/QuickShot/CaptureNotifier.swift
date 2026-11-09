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

    func notify(_ item: CaptureItem) {
        guard let center else { return }
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = item.kind == .image ? "Screenshot saved" : "Recording saved"
        content.body = "\(item.url.lastPathComponent) is in QuickShot. Click to see it."
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.itemKey: item.id]
        if let attachment = Self.attachment(for: item) { content.attachments = [attachment] }
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    /// The system moves an attachment into its own store, so it gets a copy,
    /// never the capture itself.
    private static func attachment(for item: CaptureItem) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShot-notification-\(UUID().uuidString)")
            .appendingPathExtension(item.url.pathExtension)
        guard (try? FileManager.default.copyItem(at: item.url, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: item.id, url: copy)
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
