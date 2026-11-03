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
        }, readBattery: { Self.batteryNow() })
    }
    /// The internal battery as IOPS reports it now: there or not, drawn from or not, and its percent.
    nonisolated private static func batteryNow() -> BackendOSPowerRules.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let drawing = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as NSArray?) as? [AnyObject] ?? []
        let battery = sources.lazy.compactMap { (IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as NSDictionary?) as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let battery else { return .init(present: false, discharging: false, percent: nil) }
        let current = battery[kIOPSCurrentCapacityKey] as? Int, maximum = battery[kIOPSMaxCapacityKey] as? Int
        let percent = current.map { current in maximum.map { $0 > 0 ? min(100, Int((Double(current) / Double($0) * 100).rounded())) : current } ?? current }
        return .init(present: true, discharging: drawing == kIOPSBatteryPowerValue, percent: percent)
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
        center.setNotificationCategories([UNNotificationCategory(identifier: NativeCompositionBanners.categoryIdentifier,
            actions: [], intentIdentifiers: [], options: [.customDismissAction])])
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
        let result = await NativeCompositionBanners.shared.post(title: title, body: body, silent: true)
        guard result.delivered else { throw Failure(message: result.reason ?? "Notifications are unavailable.") }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            Task { @MainActor in NativeCompositionBanners.shared.dismissed(identifier) }
        } else {
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
