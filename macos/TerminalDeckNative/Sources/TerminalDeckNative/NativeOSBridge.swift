import AppKit
@preconcurrency import UserNotifications
import IOKit.ps
import IOKit.pwr_mgt
import TerminalDeckNativeCore
import TerminalDeckBackend

/// The app's long-lived OS owners: the idle-sleep assertions and the power
/// source watch behind `BackendOSPowerControl`, the notice it posts, and the
/// notification-centre delegate (banners while the app is in front; a click
/// brings the app forward). The theme watch tells Hoot's window to repaint.
@MainActor
final class NativeOSBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NativeOSBridge()

    private var started = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var assertions: [Int: IOPMAssertionID] = [:]
    private var nativePowerObservers: [UUID: @Sendable () async -> Void] = [:]
    private var nextNativeAssertion = -1

    func powerBindings() -> BackendOSPowerBindings {
        .init(startIdleBlocker: { [weak self] in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native power owner is closed.") }
            return try await self.createNativeIdleAssertion()
        }, isIdleBlockerStarted: { [weak self] id in await self?.nativeAssertionIsActive(id) == true },
        stopIdleBlocker: { [weak self] id in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native power owner is closed.") }
            try await self.releaseNativeAssertion(id)
        },
        observePower: { [weak self] handler in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native power observer is closed.") }
            let id = await self.addNativePowerObserver(handler)
            return { [weak self] in await self?.removeNativePowerObserver(id) }
        }, notify: { [weak self] title, body in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native notification presenter is closed.") }
            try await self.presentNativeNotice(title: title, body: body)
        })
    }
    private func addNativePowerObserver(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID(); nativePowerObservers[id] = handler; return id
    }
    private func removeNativePowerObserver(_ id: UUID) { nativePowerObservers[id] = nil }
    private func createNativeIdleAssertion() throws -> Int {
        while assertions[nextNativeAssertion] != nil { nextNativeAssertion -= 1 }
        let id = nextNativeAssertion; nextNativeAssertion -= 1
        var assertion = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Terminal Deck active coding sessions" as CFString, &assertion)
        guard status == kIOReturnSuccess else { throw Failure(message: "macOS could not create the power assertion (\(status)).") }
        assertions[id] = assertion
        return id
    }
    private func nativeAssertionIsActive(_ id: Int) -> Bool {
        guard let assertion = assertions[id], let copied = IOPMAssertionCopyProperties(assertion)?.takeRetainedValue(),
              let properties = copied as? [String: Any] else { return false }
        return (properties[kIOPMAssertionLevelKey as String] as? NSNumber)?.uint32Value == UInt32(kIOPMAssertionLevelOn)
    }
    private func releaseNativeAssertion(_ id: Int) throws {
        guard let assertion = assertions[id] else { return }
        let result = IOPMAssertionRelease(assertion)
        guard result == kIOReturnSuccess else { throw NativeRPCError(code: "power", message: "macOS did not release the idle assertion (\(result)).") }
        assertions[id] = nil
    }
    private var center: UNUserNotificationCenter { .current() }

    /// Once, at launch: the notification delegate, the theme watch and the power source.
    static func connect() { shared.start() }

    private func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        let token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in NativeCompositionHootUI.shared.themeChanged() }
        }
        observers.append((DistributedNotificationCenter.default(), token))
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let bridge = Unmanaged<NativeOSBridge>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in bridge.powerSourceChanged() }
        }, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func stop() {
        NativeTranscriptBackend.shared.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        for assertion in assertions.values { IOPMAssertionRelease(assertion) }
        assertions.removeAll()
        nativePowerObservers.removeAll()
        started = false
    }

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The power owner's notice (on battery while kept awake, and the like).
    private func presentNativeNotice(title: String, body: String) async throws {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard allowed else { throw Failure(message: "Notifications were not allowed in macOS settings.") }
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw Failure(message: "Notifications are disabled for this app in macOS settings.")
        }
        guard settings.alertSetting == .enabled else { throw Failure(message: "Notification alerts are disabled for this app in macOS settings.") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await center.add(UNNotificationRequest(identifier: "native-power-" + UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            Task { @MainActor in
                NativeFrontGuard.expect("a notification click")
                NSApplication.shared.activate(ignoringOtherApps: true) // front-ok: the person clicked this app's notification
                NativeCompositionBanners.shared.clicked(identifier)
            }
        }
        completionHandler()
    }

    private func powerSourceChanged() {
        // IOPS also reports battery-capacity changes. Native power consumers
        // receive those events even when the AC/battery kind did not change.
        for handler in nativePowerObservers.values { Task { await handler() } }
    }
}
