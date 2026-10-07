import AppKit
import Foundation
import TerminalDeckNativeCore

/// Bringing the app forward only for the person (INT-A, walk-1 item 4).
///
/// A page message, an engine channel or a tool can ask for a window (Settings,
/// a pop-out, the main window) while the person is working in another app.
/// SwiftUI's `openWindow` and `NSApp.activate` both pull the whole app in
/// front of them for that. Here a request runs at once only when it answers
/// the person's own action — the app is already in front, or the event being
/// handled is their click or key press — and otherwise waits until they bring
/// the app forward themselves. Requests with the same key replace each other,
/// so a burst opens one window, once.
@MainActor
enum NativeFront {
    private static var pending: [String: @MainActor () -> Void] = [:]
    private static var order: [String] = []
    private static var observer: (any NSObjectProtocol)?

    /// The last press (click or key) the person made in one of this app's own
    /// windows, the non-activating island and Hoot panels included.
    private static var lastPress: TimeInterval?
    private static var pressMonitor: Any?
    static var secondsSincePress: Double? { lastPress.map { ProcessInfo.processInfo.systemUptime - $0 } }

    /// Watch the app's own presses (once, at launch). A hover or a scroll is not a press;
    /// keys typed into another app never reach here. AppKit turns an Accessibility press on
    /// a pop-up button or a sheet into a synthetic mouse-down, which counts — for a VoiceOver
    /// user that is the person (walk 4).
    static func watchPresses() {
        guard pressMonitor == nil else { return }
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            NativeFront.lastPress = ProcessInfo.processInfo.systemUptime
            return event
        }
    }

    /// True when taking the front answers the person (NativeFrontPolicy).
    static var personActing: Bool {
        let input: NativeFrontPolicy.Input
        switch NSApp.currentEvent?.type {
        case .leftMouseDown?, .leftMouseUp?, .rightMouseDown?, .rightMouseUp?, .otherMouseDown?, .otherMouseUp?, .keyDown?: input = .press
        case nil: input = .none
        default: input = .other
        }
        return NativeFrontPolicy.mayTakeFront(appIsActive: NSApp.isActive, currentInput: input,
            secondsSinceLastPress: lastPress.map { ProcessInfo.processInfo.systemUptime - $0 })
    }

    /// Run `bring` only for the person; otherwise drop it and say so in engine.log
    /// (a request that is not the person's is not kept for later).
    static func onlyForPerson(_ what: String, _ bring: () -> Void) {
        if personActing { bring() }
        else { AppModel.shared.engine.log.note("kept behind: " + what + " was not the person's own action") }
    }

    /// Run `open` now when the person is acting; otherwise when they next bring
    /// the app forward. The newest request for `key` is the one kept.
    static func whenPersonActs(_ key: String, _ open: @escaping @MainActor () -> Void) {
        if personActing {
            pending[key] = nil; order.removeAll { $0 == key }
            open(); return
        }
        if pending[key] == nil { order.append(key) }
        pending[key] = open
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NativeFront.flush() }
        }
    }

    private static func flush() {
        let keys = order, waiting = pending
        order = []; pending = [:]
        for key in keys { waiting[key]?() }
    }
}

/// The app coming forward without the person (walk 2, 7 Oct: twelve times, from
/// paths AppKit takes on its own — an Accessibility action in a background window,
/// a web view taking focus, a Settings section changing). Whatever brought it
/// forward, the app hands the front straight back unless the person did it:
/// their press in the app, a click or key anywhere just now (Dock, ⌘-Tab, a
/// notification, Spotlight), a request they made (Siri, a notification click),
/// or the launch they started. Every activation is noted in engine.log.
@MainActor
enum NativeFrontGuard {
    private static var lastOtherApp: NSRunningApplication?
    private static var expected: (reason: String, until: TimeInterval)?
    private static var launchedAt = ProcessInfo.processInfo.systemUptime
    private static var launchedInFront = false
    private static var installed = false

    /// A request the person made that brings the app forward (the reopen Apple event, Siri,
    /// a notification click). If the guard already handed the front back, it comes forward now.
    static func expect(_ reason: String) {
        expected = (reason, ProcessInfo.processInfo.systemUptime + 2)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) } // front-ok: the person's own request (reopen, Siri, notification)
    }

    static func install() {
        guard !installed else { return }; installed = true
        launchedAt = ProcessInfo.processInfo.systemUptime
        launchedInFront = NSApp.isActive || NSRunningApplication.current.isActive
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                lastOtherApp = app
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { becameActive() }
        }
    }

    /// The facts at the moment of activation; the reopen event and the activating click reach
    /// the app a moment after it, so the decision is taken a quarter-second later.
    private static func becameActive() {
        let commandHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
        let click = min(secondsSince(.leftMouseDown), secondsSince(.rightMouseDown), secondsSince(.otherMouseDown))
        let owner = clickOwner(at: NSEvent.mouseLocation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { decide(commandHeld: commandHeld, click: click, owner: owner) }
        }
    }
    private static func decide(commandHeld: Bool, click: Double, owner: NativeFrontPolicy.ClickOwner) {
        let now = ProcessInfo.processInfo.systemUptime
        let facts = NativeFrontPolicy.ActivationFacts(launchedInFront: launchedInFront, secondsSinceLaunch: now - launchedAt,
            expected: expected.flatMap { now <= $0.until ? $0.reason : nil }, secondsSincePressInApp: NativeFront.secondsSincePress,
            secondsSinceClick: click, clickOwner: owner, commandHeld: commandHeld)
        let log = AppModel.shared.engine.log
        if let reason = NativeFrontPolicy.activationReason(facts) { log.note("front: came forward (" + reason + ")"); expected = nil; return }
        guard NSApp.isActive else { return }
        guard let other = lastOtherApp, !other.isTerminated else {
            log.note("front: came forward without the person; no other app to give it back to"); return
        }
        log.note("front: came forward without the person — the front went back to " + (other.localizedName ?? "the previous app"))
        NSApp.yieldActivation(to: other)
        other.activate()
    }
    private static func secondsSince(_ type: CGEventType) -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }
    /// The Dock (its icons, Stage Manager and Mission Control are the Dock's and WindowManager's
    /// windows) when the topmost window under the pointer is one of theirs.
    private static func clickOwner(at point: NSPoint) -> NativeFrontPolicy.ClickOwner {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for row in rows {
            guard let box = row[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0, width: box["Width"] ?? 0, height: box["Height"] ?? 0).contains(cgPoint),
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            let owner = row[kCGWindowOwnerName as String] as? String ?? ""
            return ["Dock", "WindowManager"].contains(owner) ? .dock : .other
        }
        return .none
    }
}

/// Quitting does what TS does: the app quits even with a dialog or sheet up (an
/// Electron page's dialog never held a quit). AppKit refuses a quit while a window
/// has a sheet attached or a modal session runs, and says "cancelled" before the
/// app is even asked (walk 2) — so the sheets and the modal session go first.
@MainActor
enum NativeQuit {
    static func clearBlockers() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        }
    }
    static func terminate() {
        NativeCompositionRoot.note("quit: requested (sheets and dialogs closed first)")
        clearBlockers()
        NSApp.terminate(nil)
    }
}

/// Makes sure the main window exists and is ordered in after launch, without activating
/// the app (NativeLaunchWindowRule). A background launch gets it behind the person's work.
@MainActor
enum NativeLaunchWindow {
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") }
    }
    static func ensureShown(after delays: [Double]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { ensureShown() } }
        }
    }
    static func ensureShown() {
        let main = mainWindow()
        let action = NativeLaunchWindowRule.action(mainExists: main != nil, mainVisible: main?.isVisible == true,
            mainMiniaturized: main?.isMiniaturized == true, appActive: NSApp.isActive, appHidden: NSApp.isHidden,
            terminating: AppModel.shared.isTerminating)
        let log = AppModel.shared.engine.log
        switch action {
        case .none: return
        case .orderFront: main?.orderFront(nil) // front-ok: the app is already in front
        case .orderBack: main?.orderBack(nil) // front-ok: ordered in behind the person's work, never activated
        case .open:
            // SwiftUI's own Window ▸ "<main window>" item opens the scene; the app is not activated.
            guard let item = mainSceneMenuItem(), let selector = item.action else {
                log.note("launch: the main window does not exist and its Window menu item was not found"); return
            }
            NSApp.sendAction(selector, to: item.target, from: item)
            DispatchQueue.main.async { MainActor.assumeIsolated { if !NSApp.isActive { mainWindow()?.orderBack(nil) } } } // front-ok: behind the person's work
        }
        log.note("launch: main window " + (action == .open ? "opened" : "ordered in") + (NSApp.isActive ? "" : " behind the app in front (not activated)"))
    }
    /// SwiftUI lists each `Window` scene by its title in the Window menu.
    private static func mainSceneMenuItem() -> NSMenuItem? {
        let title = "Terminal Deck"
        var queue = NSApp.mainMenu?.items ?? []
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if item.title == title, item.action != nil, item.submenu == nil { return item }
            queue.append(contentsOf: item.submenu?.items ?? [])
        }
        return nil
    }
}
