import Foundation
import AppKit

/// updates/window-focus.ts's detach handle. No background task, timer or
/// observer is started until the owning updater explicitly subscribes.
public final class BackendAppWindowFocusSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter?
    private var token: (any NSObjectProtocol)?
    private var active: Bool
    fileprivate init(center: NotificationCenter?) { self.center = center; active = center != nil }
    fileprivate var attached: Bool { lock.lock(); defer { lock.unlock() }; return active }
    fileprivate func install(_ observer: any NSObjectProtocol) {
        lock.lock(); let keep = active; if keep { token = observer }; lock.unlock()
        if !keep { center?.removeObserver(observer) }
    }
    public func cancel() {
        lock.lock(); active = false; let observer = token; token = nil; lock.unlock()
        if let observer { center?.removeObserver(observer) }
    }
    deinit { cancel() }
}

public enum BackendAppWindowFocus {
    public static let event = NSWindow.didBecomeKeyNotification
    /// Unlike application-did-become-active, this reports switching between
    /// windows while Terminal Deck is already active, including popout windows.
    @MainActor public static func subscribe(center: NotificationCenter? = .default,
                                            listener: @escaping @MainActor @Sendable () -> Void) -> BackendAppWindowFocusSubscription {
        let subscription = BackendAppWindowFocusSubscription(center: center)
        guard let center else { return subscription }
        let token = center.addObserver(forName: event, object: nil, queue: .main) { [weak subscription] _ in
            guard subscription?.attached == true else { return }
            // NotificationCenter's explicitly selected main OperationQueue is
            // the AppKit/main-actor delivery boundary, not the posting thread.
            MainActor.assumeIsolated { listener() }
        }
        subscription.install(token); return subscription
    }
}
