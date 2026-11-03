import Foundation

/// When the app may take the front of the screen (walk 1, 7 Oct 2026: a copy
/// pulled itself in front of the app the person was typing in, and their keys
/// changed its Settings).
///
/// Only the person brings it forward: the app is already in front, the event
/// being handled is their own press (a click or a key in one of the app's
/// windows, its non-activating island included), or such a press happened in
/// the app a moment ago (a click in a page that reaches the app as a message,
/// a short hop later). A hover, a scroll, a timer, a
/// page or channel request and anything from the background never do. (An Accessibility
/// press on a pop-up or sheet arrives as AppKit's synthetic mouse-down and counts: for a
/// VoiceOver user that is the person.)
public enum NativeFrontPolicy {
    public enum Input: Equatable, Sendable { case press, other, none }
    /// A press in one of the app's own windows still counts this long after it.
    public static let pressWindowSeconds: TimeInterval = 1.5

    public static func mayTakeFront(appIsActive: Bool, currentInput: Input, secondsSinceLastPress: TimeInterval?) -> Bool {
        if appIsActive || currentInput == .press { return true }
        guard let elapsed = secondsSinceLastPress else { return false }
        return elapsed >= 0 && elapsed <= pressWindowSeconds
    }

    /// Where the last click landed, as far as an activation can tell.
    public enum ClickOwner: Equatable, Sendable { case dock, other, none }
    /// What is known the moment the app came forward.
    public struct ActivationFacts: Equatable, Sendable {
        public var launchedInFront = false, secondsSinceLaunch: Double = .infinity
        /// A request the person made that brings the app forward: the reopen Apple event
        /// (Dock icon, Spotlight, a launcher), Siri or Shortcuts, a notification click.
        public var expected: String?
        /// The person's last click or key in one of the app's own windows.
        public var secondsSincePressInApp: Double?
        public var secondsSinceClick: Double = .infinity, clickOwner: ClickOwner = .none
        /// Command held as the app came forward (⌘-Tab).
        public var commandHeld = false
        public init(launchedInFront: Bool = false, secondsSinceLaunch: Double = .infinity, expected: String? = nil,
                    secondsSincePressInApp: Double? = nil, secondsSinceClick: Double = .infinity,
                    clickOwner: ClickOwner = .none, commandHeld: Bool = false) {
            self.launchedInFront = launchedInFront; self.secondsSinceLaunch = secondsSinceLaunch; self.expected = expected
            self.secondsSincePressInApp = secondsSincePressInApp; self.secondsSinceClick = secondsSinceClick
            self.clickOwner = clickOwner; self.commandHeld = commandHeld
        }
    }
    /// Why an activation is the person's, or nil (the front goes straight back). Typing in
    /// another app is never the person (walk 1: his keys landed in this app's Settings).
    public static func activationReason(_ facts: ActivationFacts) -> String? {
        if let expected = facts.expected { return expected }
        // The launch the person started: macOS activates a foreground launch as it finishes
        // launching; a background launch (open -g, a login item) gets no such grace later on.
        if facts.secondsSinceLaunch >= 0, facts.secondsSinceLaunch < (facts.launchedInFront ? 5 : 1) { return "launch" }
        if let press = facts.secondsSincePressInApp, press >= 0, press <= pressWindowSeconds { return "a press in the app" }
        if facts.clickOwner == .dock, facts.secondsSinceClick >= 0, facts.secondsSinceClick <= pressWindowSeconds { return "a click on the Dock" }
        if facts.commandHeld { return "⌘-Tab" }
        return nil
    }

    /// The source rule its test holds every window-raising call in the app to:
    /// a call is allowed only on a line that is itself gated (`NativeFront.`) or
    /// inside a gated closure, or carries `front-ok:` with the person-initiated reason.
    public static let raisingCalls = ["NSApp.activate(", "NSApplication.shared.activate(", "makeKeyAndOrderFront(",
                                      "orderFrontRegardless(", "orderFront(nil)", "openWindow(value:", "openWindow(id:",
                                      ".activate()", "runModal()"]
    public static let allowMarker = "front-ok:"
}

/// The main window after launch (verify run, 7 Oct: after a background launch the main
/// window never appeared — SwiftUI orders it in only once the app is activated, and the
/// app no longer activates itself). The front gate may decline to activate; it never
/// stops the main window from being there.
public enum NativeLaunchWindowRule {
    public enum Action: Equatable, Sendable { case none, open, orderFront, orderBack }
    public static func action(mainExists: Bool, mainVisible: Bool, mainMiniaturized: Bool,
                              appActive: Bool, appHidden: Bool, terminating: Bool) -> Action {
        if terminating || appHidden || mainMiniaturized { return .none }
        if !mainExists { return .open }
        if mainVisible { return .none }
        // In front only for an app that is already active; behind the person's work otherwise.
        return appActive ? .orderFront : .orderBack
    }
}
