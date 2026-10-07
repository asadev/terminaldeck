import AppKit
@preconcurrency import UserNotifications
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The Mac banners the TS app showed with Electron's `Notification`, posted
/// through the notification centre (NativeOSBridge is its delegate):
///  - the page's own banners (session finished, needs input, an AI app asking,
///    Settings › Notifications' test banner): native-shell/notifications.ts over
///    `native-shell:notify` / `-notify-close`, a click answered on
///    `native-shell:notification-click`;
///  - task reminders (deck-control ELECTRON_TASK_REMINDERS: a click shows the task);
///  - plugin notices (deck-control services.notify: "<plugin>: <title>").
/// Silent like Electron's `silent: true`; "shown" means macOS took it, which is
/// the most an app can know (TS says the same).
@MainActor
final class NativeCompositionBanners: BackendOSBannerFactory {
    static let shared = NativeCompositionBanners()
    private var live: [String: NativeCompositionBanner] = [:]
    var supported: Bool { true }   // TS Notification.isSupported() on a Mac
    func make(title: String, body: String, silent: Bool) throws -> any BackendOSBanner {
        NativeCompositionBanner(owner: self, title: title, body: body, silent: silent)
    }
    fileprivate func hold(_ banner: NativeCompositionBanner) { live[banner.identifier] = banner }
    fileprivate func release(_ identifier: String) { live[identifier] = nil }
    /// The delegate's click: the banner's own handler runs once; false when it is not one of ours.
    @discardableResult func clicked(_ identifier: String) -> Bool {
        guard let banner = live.removeValue(forKey: identifier) else { return false }
        banner.fireClicked(); return true
    }
    /// One banner, posted now; the outcome is macOS's (TS ELECTRON_TASK_REMINDERS wording).
    func post(title: String, body: String, clicked: (@MainActor () -> Void)? = nil) async -> BackendTaskReminderDelivery {
        let banner = NativeCompositionBanner(owner: self, title: title, body: body, silent: false)
        if let clicked { banner.clicked(clicked) }
        do { try await banner.deliver(); return .init(delivered: true) }
        catch { return .init(delivered: false, reason: "this computer does not show notifications from the app", retry: false) }
    }
}

@MainActor
final class NativeCompositionBanner: BackendOSBanner {
    let identifier = "td-banner-" + UUID().uuidString
    private weak var owner: NativeCompositionBanners?
    private let title: String, body: String, silent: Bool
    private var onClick: (@MainActor () -> Void)?
    private var onClose: (@MainActor () -> Void)?
    private var closedOnce = false
    fileprivate init(owner: NativeCompositionBanners, title: String, body: String, silent: Bool) {
        self.owner = owner; self.title = title; self.body = body; self.silent = silent
    }
    func show() throws { Task { try? await deliver() } }
    func close() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        owner?.release(identifier); fireClosed()
    }
    func clicked(_ callback: @escaping @MainActor () -> Void) { onClick = callback }
    func closed(_ callback: @escaping @MainActor () -> Void) { onClose = callback }
    fileprivate func fireClicked() { onClick?(); onClick = nil; fireClosed() }
    private func fireClosed() { guard !closedOnce else { return }; closedOnce = true; onClose?() }
    fileprivate func deliver() async throws {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            owner?.release(identifier); fireClosed()
            throw NativeRPCError(code: "unavailable", message: "Notifications are turned off for this app in macOS settings.")
        }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if !silent { content.sound = .default }
        owner?.hold(self)
        do { try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) }
        catch { owner?.release(identifier); fireClosed(); throw error }
    }
}

extension NativeCompositionProduction {
    /// native-shell/notifications.ts channels for the app's pages, over the one banner owner.
    func installNotifications() async throws {
        let owner = "native-composition:notifications"
        let registry = root.registry
        let notifier = BackendOSNativeNotifier(factory: NativeCompositionBanners.shared) { channel, arguments in
            Task { try? await registry.publish(channel, arguments: arguments, ownerID: BackendCompositionRoot.appOwnerID) }
        }
        try await notifier.register(registry: registry, ownerID: owner)
        notifications = notifier
        try await root.retain(.init(name: "notifications", domains: ["notifications"], ownerID: owner,
            invokes: [BackendOSNativeNotifier.notifyChannel, BackendOSNativeNotifier.closeChannel],
            events: [BackendOSNativeNotifier.clickChannel],
            stop: { [registry] in await registry.removeOwner(owner) }))
    }
}
