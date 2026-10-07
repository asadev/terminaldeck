import Foundation
import TerminalDeckNativeCore

/// Lane BR: what a session's agent is told about the browser windows attached to
/// it — browser-binding.ts `hookContext` (top of a turn: SessionStart,
/// UserPromptSubmit) and `takeAnnouncement` (the middle of one: PostToolUse /
/// AfterTool), with index.ts `contextFor` choosing between them. Same sentences.
///
/// It reads the one binding map through its `browser:bindings` view (fed on every
/// change) and marks a session "unannounced" exactly when the set of windows it
/// holds changes — attach, detach, close, exit — never for a title or address.
public final class BRBrowserSessionContext: @unchecked Sendable {
    public static let discretion = "Do not mention any of this unless it is asked about or you act on it."
    /// Claude's PostToolUse and Gemini's AfterTool: the change, and nothing else.
    public static let midTurnEvents: Set<String> = ["PostToolUse", "AfterTool"]

    private let lock = NSLock()
    private var rows: [String: BRBoundSession] = [:]
    private var unannounced: Set<String> = []
    private let appName: String

    public init(appName: String = BackendSharedBrand.name) { self.appName = appName }

    private static func key(_ sessionID: String, _ machineID: String) -> String {
        BrowserBindings.key(BrowserDriverSession(sessionId: sessionID, machineId: machineID))
    }

    /// The map as it is now (`BackendBrowserBindings.view(for:)` of a window-managing principal).
    public func update(_ view: NativeRPCValue) { update(BRBindingView.read(view.foundation)) }

    public func update(_ view: BRBindingView) {
        lock.withLock {
            var next: [String: BRBoundSession] = [:]
            for session in view.sessions { next[session.key] = session }
            for (key, session) in next {
                let before = rows[key]?.windows.map(\.tabId) ?? []
                if before != session.windows.map(\.tabId) { unannounced.insert(key) }
            }
            // sessionRemoved: nothing left to tell, and nobody left to tell it to.
            for key in rows.keys where next[key] == nil { unannounced.remove(key) }
            rows = next
        }
    }

    public func hasAnnouncement(sessionID: String, machineID: String = "") -> Bool {
        lock.withLock { unannounced.contains(Self.key(sessionID, machineID)) }
    }

    /// `B2 — Stripe — https://… — served by DESKTOP`
    static func line(_ window: BRBoundWindow) -> String {
        var line = [window.slot, window.title, window.url].filter { !$0.isEmpty }.joined(separator: " — ")
        if !window.host.isEmpty { line += " — served by \(window.host)" }
        return line
    }

    /// The change since the agent last heard, said once; nil when nothing changed.
    public func takeAnnouncement(sessionID: String, machineID: String = "", cannotDrive: String? = nil) -> String? {
        lock.withLock {
            let key = Self.key(sessionID, machineID)
            guard unannounced.remove(key) != nil else { return nil }
            let windows = rows[key]?.windows ?? []
            guard let first = windows.first else { return "No browser window is attached to this session now." }
            var lines = ["Browser windows attached to this session (this just changed):"]
            lines += windows.map(Self.line)
            lines.append("\"the browser\" means \(first.slot).")
            if let cannotDrive, !cannotDrive.isEmpty { lines.append(cannotDrive) }
            lines.append(Self.discretion)
            return lines.joined(separator: "\n")
        }
    }

    /// The standing answer at the top of a turn; nil for a session this app did not
    /// start and that holds no window (the endpoint's empty 204).
    public func hookContext(sessionID: String?, machineID: String = "", known: Bool, opensInApp: Bool,
                            map: String? = nil, cannotDrive: String? = nil) -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return lock.withLock {
            let key = Self.key(sessionID, machineID)
            let windows = rows[key]?.windows ?? []
            if !known && windows.isEmpty { return nil }
            var lines = ["You are running inside \(appName), a terminal app with browser windows of its own."]
            if let map, !map.isEmpty { lines.append(map) }
            if let first = windows.first {
                lines.append("Browser windows attached to this session:")
                lines += windows.map(Self.line)
                // Said in full here, so the change need not be said again mid-turn.
                unannounced.remove(key)
                lines.append(opensInApp
                    ? "\"the browser\" means \(first.slot). `open <url>` goes to \(first.slot) unless you detach it."
                    : "\"the browser\" means \(first.slot).")
                if let cannotDrive, !cannotDrive.isEmpty { lines.append(cannotDrive) }
            } else if opensInApp {
                lines.append("`open <url>` here opens a browser window in this app, not the machine's browser.")
            }
            lines.append(Self.discretion)
            return lines.joined(separator: "\n")
        }
    }

    /// index.ts `contextFor`: the change mid-turn, the standing answer otherwise.
    public func answer(event: String, sessionID: String?, machineID: String = "", known: Bool, opensInApp: Bool,
                       map: String? = nil, cannotDrive: String? = nil) -> String? {
        if Self.midTurnEvents.contains(event) {
            guard let sessionID, !sessionID.isEmpty else { return nil }
            return takeAnnouncement(sessionID: sessionID, machineID: machineID, cannotDrive: cannotDrive)
        }
        return hookContext(sessionID: sessionID, machineID: machineID, known: known, opensInApp: opensInApp,
                           map: map, cannotDrive: cannotDrive)
    }
}
