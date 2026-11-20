import Foundation
import TerminalDeckNativeCore

/// Asad, 19 Nov 2026 (notes/overnight-20261118/PAYMENTS-DESIGN.md, "19 Nov changes"): a FREE account reaches the
/// sessions on its computers from its other devices, and nothing more ("they will only be able to see the remote
/// sessions. Not the browser windows, not simulators, not cloud storage, not devices screen sharing"). The relay
/// cannot see inside the sealed link, so the computer serving the link enforces it: with the paywall on and its own
/// account's tier free (`CloudSubscription.limitsRemoteToSessions`), it refuses the request kinds below with ONE plain
/// reason the other device shows as its upgrade line.
///
/// Everything else stays served for a free account: the session list, view, type, continue, start a new session,
/// close and rename, chats, Projects, Hoot, Activity, pictures, alerts, folders to start in (Decker, 20 Nov: those
/// are session features). Local use of this computer is never touched by this list.
///
/// Windows copies this list EXACTLY (its `RemoteFreePlan`): the same kinds, the same error frame.
public enum BackendRemoteFreePlan {
    /// Kinds refused by their start: browser windows (`browser.windows`, `browser.window.*`, the window stream
    /// `browser.watch`/`browser.input`/... and browser profiles); this computer's local web pages through the localhost
    /// tunnel (`tunnel.open`/`tunnel.close`, `net.*`; Decker, 20 Nov: "together with browser windows"); simulator,
    /// device and this computer's own screens (`sims.*`: list, watch, input, touch, record, keys, stills, Annotate and
    /// the Mac sign-in screen); files (`files.list`, `files.read`).
    public static let paidPrefixes: [String] = ["browser.", "tunnel.", "net.", "sims.", "files."]
    /// Single kinds refused: a session on another computer driving this computer's browser windows, and the list of
    /// this computer's local web ports (the localhost tunnel's first read).
    public static let paidKinds: Set<String> = ["window.call", "ports"]
    /// Pages read or acted on through `panel.read` / `panel.act` that are paid: Tasks (with connected task systems)
    /// and the Simulators page. Every other page (Projects, Agents, ...) stays served.
    public static let paidPanels: Set<String> = ["tasks", "connected-tasks", "simulators"]
    static let panelKinds: Set<String> = ["panel.read", "panel.act"]

    /// The error frame: `code` is one every client already knows (an iPhone drops an error frame whose code it does
    /// not know), `reason` is what a newer client reads to show its upgrade line, `message` is the line itself.
    public static let code = "unauthorized"
    public static let reason = "subscription_required"
    public static let words = "Part of Terminal Deck Cloud"

    /// Whether a request kind is part of Terminal Deck Cloud (refused for a free account).
    public static func isPaid(_ kind: String, panel: String?) -> Bool {
        if paidKinds.contains(kind) || paidPrefixes.contains(where: { kind.hasPrefix($0) }) { return true }
        if panelKinds.contains(kind), let panel { return paidPanels.contains(panel) }
        return false
    }

    /// `{"t":"error","code":"unauthorized","reason":"subscription_required","message":"Part of Terminal Deck Cloud"}`;
    /// the host adds the request's `rid` when it has one.
    public static func refusal() throws -> BackendRemoteServerMessage {
        try BackendRemoteServerMessage(.error, fields: [.init("code", .string(code)), .init("reason", .string(reason)),
                                                        .init("message", .string(words))])
    }
}
