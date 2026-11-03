import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// L8 (11 Oct). Asad: "session app restart should not lose any session, even sessions by hand and even session
/// by app … everything for Hoot as well, so Hoot can continue after that."
///
/// Sessions he starts by hand live in the session host and simply go on. Sessions the APP starts for a task (an
/// agent's worker) and Hoot's task turns run inside the app, so a restart ends them. At start the task engine
/// already notices that (it releases the dead session and writes "Terminal Deck restarted while this was running"
/// or "Stopped: the app was closed while this was being worked on"). Until now the person had to reply on the
/// task to go on. Here the app does that reply itself, once, through the engine's own reply path:
/// - an agent's task continues in its SAME conversation (the engine resumes the saved conversation id, e.g.
///   `claude --resume <id>`), told in one line that the app restarted;
/// - a task Hoot was working on goes back to Hoot as a new task turn on that task.
/// Only what the task engine recorded as interrupted during this very start is continued; a task that was
/// stopped, finished or left before is never woken. Saved tabs of task workers are not restored separately
/// (BackendSessionRestoreCoordinator), so nothing starts twice.
extension NativeCompositionProduction {
    static let restartLine = "Terminal Deck was restarted while you were working on this task. Carry on exactly where you left off; your earlier work in this conversation still counts."
    /// The one reading of the setting (missing = on: no session or task work is lost on a restart by default).
    nonisolated static func picksUpAfterRestart(_ preferences: NativeRPCValue) -> Bool { preferences["restoreSessions"].bool != false }

    /// Called once Hoot's start at launch is settled (awake or not), when the task engine is already running.
    func continueAfterRestart() async {
        guard let engine = taskEngine else { return }
        // SETTINGS-TRUTH row 55: "Pick up where you left off" (on unless he turns it off). Off: interrupted task work
        // stays handed back to him on its task, and a reply there carries it on.
        guard Self.picksUpAfterRestart(await root.state.getPreferences()) else {
            report("restart: Pick up where you left off is off, so interrupted task work waits for a reply on its task"); return
        }
        var continued: [String] = []
        // An interrupted agent's task was handed back to the person at start ("Handed to you"): it still names its
        // agent in handedFrom, and a reply gives it back to that agent, exactly as the person's own reply would.
        for id in await engine.interruptedTaskIDs() {
            do {
                if try await engine.continueInterruptedTask(id, text: Self.restartLine) { continued.append(id) }
                else { report("After the restart, task \(id) was already handled or is no longer pending.") }
            }
            catch { report("After the restart, task \(id) could not be continued by itself: " + error.localizedDescription + " (a reply on the task continues it).") }
        }
        if !continued.isEmpty { report("restart: \(continued.count) interrupted task(s) continued by themselves") }
    }
}
