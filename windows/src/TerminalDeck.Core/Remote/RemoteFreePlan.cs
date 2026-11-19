using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// Asad, 19 Nov 2026 (notes/overnight-20261118/PAYMENTS-DESIGN.md, "19 Nov changes"): a FREE account reaches the sessions
// on its computers from its other devices, and nothing more ("they will only be able to see the remote sessions. Not the
// browser windows, not simulators, not cloud storage, not devices screen sharing"). The relay cannot see inside the
// sealed link, so this PC enforces it: with the paywall on and its own account's tier free
// (`CloudSubscriptionSnapshot.LimitsRemoteToSessions`), it refuses the request kinds below with ONE plain reason the other
// device shows as its upgrade line.
//
// The Mac's list, copied exactly (BackendRemoteFreePlan.swift, lane/mac-free-tier 029a89bb2): the same kinds, the same
// error frame. Everything else stays served for a free account: the session list, view, type, continue, start a new
// session, close and rename, chats, Projects, Hoot, Activity, pictures, alerts and folders to start in. Local use of
// this PC is never touched by this list.
public static class RemoteFreePlan
{
  /// Kinds refused by their start: browser windows (`browser.windows`, `browser.window.*`, the window stream
  /// `browser.watch`/`browser.input`/... and browser profiles); this PC's local web pages through the localhost tunnel
  /// (`tunnel.open`/`tunnel.close`, `net.*`); this PC's own screen and its Android devices (`sims.*`); files
  /// (`files.list`, `files.read`).
  public static readonly IReadOnlyList<string> PaidPrefixes = ["browser.", "tunnel.", "net.", "sims.", "files."];
  /// Single kinds refused: a session on another computer driving this PC's browser windows, and the list of this PC's
  /// local web ports (the localhost tunnel's first read).
  public static readonly IReadOnlySet<string> PaidKinds = new HashSet<string>(StringComparer.Ordinal) { "window.call", "ports" };
  /// Pages read or acted on through `panel.read` / `panel.act` that are paid: Tasks (with connected task systems) and
  /// the Simulators page. Every other page (Projects, Agents, ...) stays served.
  public static readonly IReadOnlySet<string> PaidPanels = new HashSet<string>(StringComparer.Ordinal) { "tasks", "connected-tasks", "simulators" };

  /// The error frame: `code` is one every client already knows (an iPhone drops an error frame whose code it does not
  /// know), `reason` is what a newer client reads to show its upgrade line, `message` is the line itself.
  public const string Code = "unauthorized";
  public const string Reason = "subscription_required";
  public const string Words = "Part of Terminal Deck Cloud";

  /// Whether a request kind is part of Terminal Deck Cloud (refused for a free account).
  public static bool IsPaid(string kind, string? panel)
  {
    if (PaidKinds.Contains(kind) || PaidPrefixes.Any(prefix => kind.StartsWith(prefix, StringComparison.Ordinal))) return true;
    return kind is "panel.read" or "panel.act" && panel is not null && PaidPanels.Contains(panel);
  }

  /// `{"t":"error","code":"unauthorized","reason":"subscription_required","message":"Part of Terminal Deck Cloud"}`,
  /// with the request's `rid` last when it has one (the Mac stamps it the same way).
  public static JsonObject Refusal(string? rid)
  {
    var frame = new JsonObject { ["t"] = "error", ["code"] = Code, ["reason"] = Reason, ["message"] = Words };
    if (rid is not null) frame["rid"] = rid;
    return frame;
  }

  /// A refusal frame from the other computer (this PC as a guest): the request is refused, the connection stays.
  public static bool IsRefusal(System.Text.Json.JsonElement frame) =>
    frame.ValueKind == System.Text.Json.JsonValueKind.Object && frame.TryGetProperty("reason", out var reason)
    && reason.ValueKind == System.Text.Json.JsonValueKind.String && reason.GetString() == Reason;
}
