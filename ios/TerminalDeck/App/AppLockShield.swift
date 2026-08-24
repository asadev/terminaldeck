/**
 * The lock screen lives in a window of its own, and that is not architecture for
 * its own sake.
 *
 * The obvious build is a `ZStack` over `RootView`, and it has a hole in it big
 * enough to drive the whole feature through. Every sheet in this app is
 * presented *from* `RootView` — the server login with a password in the field,
 * the GitHub account, the credential prompt a machine raised. A sheet is a
 * modal presentation on the window's root view controller, so it is drawn
 * **above** anything that view's own body puts on screen. Re-lock while one is
 * open and the lock screen appears politely underneath the very thing it was
 * supposed to cover.
 *
 * A `UIWindow` above `.alert` has no such ordering question. It covers the root
 * view controller, every sheet presented from it, and the app-switcher snapshot,
 * because at that level there is nothing left to be above.
 *
 * ## Two jobs, one window
 *
 *  - **Locked** — the lock screen, with the prompt and the way through.
 *  - **Shielded** — the app is going inactive with the lock on, so the snapshot
 *    iOS is about to take for the app switcher gets the brand mark instead of
 *    somebody's production terminal. Same window, no lock screen, and it comes
 *    off the instant the app is active again.
 *
 * ## Why the colour scheme is set here in UIKit
 *
 * `RootView` is the one place in this app allowed to state a colour scheme, and
 * `AppearanceTests.testNothingButTheRootStatesAColourScheme` walks the source to
 * keep it that way. That rule is about *screens overriding the setting*, and it
 * is right. This is a second window, which `RootView`'s modifier cannot reach at
 * all — so the same setting is applied to it the way UIKit states it for a
 * window, `overrideUserInterfaceStyle`, read from the same defaults key. It is
 * the same preference reaching the same place by the only route available, not
 * a second opinion about it.
 */

import SwiftUI
import UIKit

@MainActor
final class AppLockWindow {

    static let shared = AppLockWindow()

    private var window: UIWindow?

    private init() {}

    /// Put the cover up or take it down. Called on every change of
    /// `AppLock.isCovered`, and once when the app's root view appears — a cold
    /// start into a locked app has to raise this on the first pass, not after a
    /// frame of the session list.
    func sync(_ lock: AppLock) {
        guard lock.isCovered else {
            window?.isHidden = true
            return
        }
        let window = window ?? make(for: lock)
        guard let window else { return }
        window.overrideUserInterfaceStyle = Appearance.stored().interfaceStyle
        window.isHidden = false
    }

    private func make(for lock: AppLock) -> UIWindow? {
        guard let scene = Self.scene() else { return nil }
        let window = UIWindow(windowScene: scene)
        // Above `.alert`, which is where system alerts and the biometric sheet's
        // host live. The lock screen has to be above every one of them for the
        // same reason it has to be above a sheet.
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: AppLockCover(lock: lock))
        // The hosting controller's own background would otherwise be the system
        // background rather than the theme's, which shows as a one-frame flash of
        // the wrong colour on the way up.
        window.rootViewController?.view.backgroundColor = UIColor(Theme.background)
        // Never `makeKeyAndVisible`. Touches go to the front-most window that
        // contains them whatever is key, and stealing key status from the main
        // window is how a text field three screens down loses its keyboard when
        // the app comes back.
        window.isHidden = true
        self.window = window
        return window
    }

    /// The scene this app is actually on. The key window's scene when there is
    /// one, and any attached window scene otherwise — which is the case during
    /// the very first layout pass, before anything is key.
    private static func scene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.windows.contains(where: \.isKeyWindow) }
            ?? scenes.first { $0.activationState != .unattached }
            ?? scenes.first
    }
}

/// What the window holds: the lock screen when the app is locked, and the plain
/// mark when it is merely shielded on the way into the app switcher.
private struct AppLockCover: View {
    let lock: AppLock

    var body: some View {
        if lock.isLocked {
            AppLockScreen(lock: lock)
        } else {
            AppLockMark()
        }
    }
}

/**
 * A padlock on the theme's own background: what the app switcher gets in place
 * of somebody's terminal, and what fills the second between a cold start and
 * the lock screen being on screen.
 *
 * Photographed, which is why it exists: a locked cold start showed **plain
 * white** for about a second — the app's own content is already at zero opacity
 * by then and the window's backdrop is the system's, not this app's. On a phone
 * set to Dark that was a white flash on every launch.
 */
struct AppLockMark: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.faint)
        }
        .accessibilityIdentifier("applock.mark")
    }
}

extension View {
    /**
     * Keep the lock window in step with the lock, and cover the app's own
     * content while it is up.
     *
     * Two layers, and both earn their place. The **window** is what actually
     * covers everything, sheets included — see the top of this file. The
     * **mark** underneath it is what is on screen in the second before that
     * window exists: `onAppear` is the earliest a SwiftUI view can reach UIKit,
     * and a cold start spends about a second getting there.
     */
    func appLock(_ lock: AppLock) -> some View {
        self
            .opacity(lock.isCovered ? 0 : 1)
            // Behind the hidden content rather than in a `ZStack` with it. A
            // `ZStack` here put a second tab bar in the accessibility tree —
            // `openSettingsTab()` started failing with "Multiple matching
            // elements found" the moment one went in — and this composes the
            // same picture without adding a container around the whole app.
            .background(lock.isCovered ? AppLockMark() : nil)
            .onAppear { AppLockWindow.shared.sync(lock) }
            .onChange(of: lock.isCovered) { _, _ in AppLockWindow.shared.sync(lock) }
    }
}
