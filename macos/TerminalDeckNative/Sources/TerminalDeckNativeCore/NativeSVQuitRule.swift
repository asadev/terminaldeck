import Foundation

/// What quitting means while sessions run (TS resident.ts `plannedQuit` / `quitAnswer` and the
/// index.ts `before-quit` handler). Pure, so every answer is pinned in a test rather than living
/// inside a dialog callback. The app side is NativeSVResident.
public enum NativeSVQuitRule {
    public enum Plan: String, Sendable, Equatable { case stop, keep, ask }
    public enum Answer: String, Sendable, Equatable { case keep, stop, cancel }

    /// The buttons on the quit question, in the order they are drawn (TS QUIT_BUTTONS).
    public static let buttons = ["Keep Them Running", "Stop Everything", "Cancel"]
    /// TS `checkboxLabel`.
    public static let rememberLabel = "Do this from now on, and stop asking"

    /// TS before-quit. `stopping`: the quit was already decided — "Quit and Stop All Sessions",
    /// an update being installed, a signal, or the answer to the question itself. A quit while
    /// the app is already in the background is never "keep" (Quit would then do nothing, over
    /// and over); with nothing running, quitting quits with no question.
    public static func plan(liveSessions: Int, behavior: NativeStateStore.QuitBehavior, stopping: Bool, inBackground: Bool) -> Plan {
        guard !stopping, liveSessions > 0 else { return .stop }
        switch behavior {
        case .ask: return .ask
        case .keep: return inBackground ? .stop : .keep
        case .stop: return .stop
        }
    }

    /// TS quitAnswer: 0 keep, 1 stop, anything else (Cancel, Escape, an aborted dialog) cancel.
    public static func answer(buttonIndex: Int) -> Answer {
        buttonIndex == 0 ? .keep : buttonIndex == 1 ? .stop : .cancel
    }

    /// Remembered only for the answer actually given, and only when the box was ticked.
    public static func remembered(_ answer: Answer, checkbox: Bool) -> NativeStateStore.QuitBehavior? {
        guard checkbox else { return nil }
        switch answer { case .keep: return .keep; case .stop: return .stop; case .cancel: return nil }
    }

    /// TS window-all-closed: no window is no reason to end anything while the app is resident
    /// or the question is on screen; otherwise the last window closing asks to quit as before.
    public static func quitsWhenLastWindowCloses(inBackground: Bool, asking: Bool) -> Bool { !inBackground && !asking }

    /// TS quitQuestion: names the count, and the menu-bar icon that makes keeping them safe.
    public static func question(liveSessions n: Int) -> (message: String, detail: String) {
        (n == 1 ? "One session is still running." : "\(n) sessions are still running.",
         "Quitting has always ended them. It does not have to: Terminal Deck can keep them running on this machine with no window, and put them back — screens and all — the next time you open it.\n\nWhile they are running you will find Terminal Deck in the menu bar, which lists them and can stop any of them, or all of them, without opening a window.")
    }
}
