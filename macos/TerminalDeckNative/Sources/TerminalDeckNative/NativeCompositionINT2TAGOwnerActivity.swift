import AppKit
import CoreGraphics
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Presence at this Mac, independent of which app is in front. Only the
/// existing authenticated owner window may publish it to its consent broker.
@MainActor
final class NativeCompositionINT2TAGOwnerActivity {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var locked = false
    private var stopped = false
    private var publication: Task<Void, Never>?
    private var window: BackendDeckCoreWindowConsent?
    private var broker: BackendDeckCoreSecurityConsentBroker?
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)

    var isPresent: Bool {
        guard !stopped, !sleeping, !locked,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
            && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    func start(window: BackendDeckCoreWindowConsent, broker: BackendDeckCoreSecurityConsentBroker) {
        self.window = window; self.broker = broker
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { owner in owner.sleeping = true }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { owner in owner.sleeping = false }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, .init("com.apple.screenIsLocked")) { owner in owner.locked = true }
        observe(distributed, .init("com.apple.screenIsUnlocked")) { owner in owner.locked = false; owner.sleeping = false }
        publish()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         change: @escaping @MainActor (NativeCompositionINT2TAGOwnerActivity) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                change(self); self.publish()
            }
        }
        tokens.append((center, token))
    }

    private func publish() {
        guard let window, let broker else { return }
        let active = isPresent, context = context, previous = publication
        publication = Task {
            await previous?.value
            try? await window.noteOwnerActive(context: context, broker: broker, active: active)
        }
    }

    func stop() async {
        stopped = true
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
        await publication?.value; publication = nil
        if let window, let broker { try? await window.noteOwnerActive(context: context, broker: broker, active: false) }
        window = nil; broker = nil
    }
}
