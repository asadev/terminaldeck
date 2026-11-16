import AppKit

/// When a hidden web page may take the keyboard (Owner, 14 Nov: his typing keeps landing in the wrong place). Only on
/// the first load of the launch, only when the page is what the window shows, and only when nothing else in the window
/// holds the keyboard. A page reloading itself, or coming back after its web process crashed, never moves it.
@MainActor
enum NativePageKeyboard {
    static func mayTake(firstLoad: Bool, pageOnScreen: Bool, window: NSWindow?, page: NSView) -> Bool {
        guard firstLoad, pageOnScreen, let window else { return false }
        guard let responder = window.firstResponder, responder !== window else { return true }
        if let view = responder as? NSView, view === page || view.isDescendant(of: page) { return true }
        return false
    }

    /// The event being handled now is his own click, or a ⌘-shortcut, made just now. `NativeFront.personActing` alone is
    /// true whenever the app is in front, and AppKit keeps the last event as "current" after it was handled, so a tool's
    /// change that runs right after his plain typing would pass it; plain typing never counts here.
    static func personJustPressed(event: NSEvent? = NSApp?.currentEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let event, now - event.timestamp < 0.5 else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: return true
        case .keyDown: return event.modifierFlags.contains(.command)
        default: return false
        }
    }
}
