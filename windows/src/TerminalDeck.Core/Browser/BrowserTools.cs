using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Browser;

public interface IBrowserReachability
{
  ValueTask<Uri> ReachAsync(string machineId, int port, CancellationToken cancellationToken);
  ValueTask UnreachAsync(string machineId, CancellationToken cancellationToken);
}

public static class BrowserTools
{
  public static void Register(McpDoor door, BrowserModel browser, SessionKeeper sessions, IBrowserReachability? reachability = null)
    => RegisterWithSessionLookup(door, browser, sessions.Get, reachability);
  public static void RegisterWithSessionLookup(McpDoor door, BrowserModel browser, Func<string, SessionRecord> getSession, IBrowserReachability? reachability = null)
  {
    BrowserWorkspaceTools.RegisterIfComposed(door, browser);
    door.Register("browser.open", async (c, a, ct) =>
    {
      var url = DeckCoreTools.Required(a, "url"); RequireOrigin(c, url);
      var session = DeckCoreTools.Text(a, "sessionId") ?? c.Grant.SessionId;
      if (session is not null) { c.Require("sessions", session); _ = getSession(session); }
      else RequireManager(c);
      var existing = a.TryGetProperty("newWindow", out var nw) && nw.GetBoolean() ? null : Resolve(c, a, browser, required: false);
      await c.EnsureCurrentAsync(ct);
      if (existing is not null)
      {
        if (a.TryGetProperty("isolate", out var isolated) && isolated.GetBoolean() != existing.Isolated)
          throw new McpRefusal("Open a new window to change isolation. Its sign-ins will stay separate.");
        await browser.NavigateAsync(existing.Id, url, ct); return JsonSerializer.SerializeToElement(browser.Get(existing.Id));
      }
      var profile = browser.Read().ActiveProfileId; c.Require("profiles", profile);
      var made = await browser.OpenAsync(url, a.TryGetProperty("isolate", out var isolate) && isolate.GetBoolean(), profile, session, ct);
      return JsonSerializer.SerializeToElement(made);
    });
    door.Register("browser.close", async (c, a, ct) =>
    {
      var tab = Resolve(c, a, browser)!; await c.EnsureCurrentAsync(ct); await browser.CloseAsync(tab.Id, ct);
      return JsonSerializer.SerializeToElement(new { closed = true });
    });
    door.Register("browser.windows", async (c, a, ct) =>
    {
      var action = DeckCoreTools.Text(a, "action") ?? "list";
      // A session reaches the windows linked to it (Send/attach or its own open):
      // it may list, pick, move and close those. Reaching devices and opening
      // windows for other sessions stay with the owner and Hoot (Mac: same).
      if (action == "list") return JsonSerializer.SerializeToElement(browser.Read().Tabs.Where(t => Allowed(c, t)));
      if (action is not ("select" or "move" or "close" or "open") || !Manager(c) && DeckCoreTools.Text(a, "sessionId") is { } other && other != c.Grant.SessionId) RequireManager(c);
      if (action is "reach" or "unreach")
      {
        if (DeckCoreTools.Text(a, "kind") == "server") throw new McpRefusal("Server administration is outside this version.");
        var machine = DeckCoreTools.Required(a, "machineId"); c.Require("devices", machine);
        if (reachability is null) throw new McpRefusal("This caller has no granted remote page route.");
        await c.EnsureCurrentAsync(ct);
        if (action == "unreach") { await reachability.UnreachAsync(machine, ct); return JsonSerializer.SerializeToElement(new { released = true }); }
        var port = a.GetProperty("port").GetInt32(); if (port is < 1 or > 65535) throw new McpRefusal("Choose a port from 1 to 65535.");
        var address = await reachability.ReachAsync(machine, port, ct); _ = BrowserModel.Address(address.AbsoluteUri); await c.EnsureCurrentAsync(ct);
        c.Require("profiles", browser.Read().ActiveProfileId); return JsonSerializer.SerializeToElement(await browser.OpenAsync(address.AbsoluteUri, cancellationToken: ct));
      }
      if (action == "open")
      {
        var session = DeckCoreTools.Text(a, "sessionId") ?? (Manager(c) ? null : c.Grant.SessionId);
        if (session is not null) { c.Require("sessions", session); _ = getSession(session); }
        c.Require("profiles", browser.Read().ActiveProfileId); RequireOrigin(c, DeckCoreTools.Text(a, "url") ?? "about:blank"); await c.EnsureCurrentAsync(ct);
        return JsonSerializer.SerializeToElement(await browser.OpenAsync(DeckCoreTools.Text(a, "url") ?? "about:blank", sessionId: session, cancellationToken: ct));
      }
      var tab = Resolve(c, a, browser, bindingTarget: action == "attach")!;
      if (action == "select") { await c.EnsureCurrentAsync(ct); await browser.SelectAsync(tab.Id, ct); }
      else if (action == "move") { await c.EnsureCurrentAsync(ct); await browser.MoveAsync(tab.Id, a.GetProperty("index").GetInt32(), ct); }
      else if (action == "close") { await c.EnsureCurrentAsync(ct); await browser.CloseAsync(tab.Id, ct); }
      else
      {
        var session = action == "detach" ? null : DeckCoreTools.Required(a, "sessionId");
        if (session is not null) { c.Require("sessions", session); _ = getSession(session); }
        // Both the old and the new holder must be granted before rebinding.
        if (tab.SessionId is not null) c.Require("sessions", tab.SessionId);
        await c.EnsureCurrentAsync(ct); await browser.AttachAsync(tab.Id, session, ct);
      }
      return JsonSerializer.SerializeToElement(new { done = true });
    });
    door.Register("browser.page", async (c, a, ct) =>
    {
      var tab = Resolve(c, a, browser)!; var action = DeckCoreTools.Text(a, "action") ?? "state";
      c.Require("profiles", tab.ProfileId); RequireOrigin(c, tab.Url);
      if (action == "state") return JsonSerializer.SerializeToElement(tab);
      if (action == "navigate") { RequireOrigin(c, DeckCoreTools.Required(a, "url")); await c.EnsureCurrentAsync(ct); await browser.NavigateAsync(tab.Id, DeckCoreTools.Required(a, "url"), ct); return JsonSerializer.SerializeToElement(browser.Get(tab.Id)); }
      if (action == "reload") { await c.EnsureCurrentAsync(ct); await browser.ReloadAsync(tab.Id, cancellationToken: ct); return JsonSerializer.SerializeToElement(new { reloaded = true }); }
      if (action == "reveal") { RequireManager(c); c.Require("captures", DeckCoreTools.Required(a, "path")); }
      if (!Enum.TryParse<BrowserPageAction>(action, ignoreCase: true, out var operation)) throw new McpRefusal("Choose a listed browser action.");
      await c.EnsureCurrentAsync(ct); var result = await browser.PerformAsync(tab.Id, operation, a, ct);
      if (result.TryGetProperty("url", out var currentUrl)) RequireOrigin(c, currentUrl.GetString()!);
      await c.EnsureCurrentAsync(ct); return result;
    });
    foreach (var (tool, operation) in new[] { ("browser.read", BrowserPageAction.Read), ("browser.step", BrowserPageAction.Step), ("browser.screenshot", BrowserPageAction.Screenshot), ("browser.handover", BrowserPageAction.Handover) })
      door.Register(tool, async (c, a, ct) =>
      {
        var tab = Resolve(c, a, browser)!; c.Require("profiles", tab.ProfileId); RequireOrigin(c, tab.Url);
        await c.EnsureCurrentAsync(ct);
        if (operation == BrowserPageAction.Handover) await browser.SelectAsync(tab.Id, ct);
        var result = await browser.PerformAsync(tab.Id, operation, a, ct);
        if (result.TryGetProperty("url", out var currentUrl)) RequireOrigin(c, currentUrl.GetString()!);
        await c.EnsureCurrentAsync(ct); return result;
      });
    door.Register("browser.profiles", async (c, a, ct) =>
    {
      RequireManager(c); var action = DeckCoreTools.Text(a, "action") ?? "list";
      var visible = browser.Read().Profiles.Where(p => c.Has("profiles", p.Id)).ToArray();
      if (action == "list") return JsonSerializer.SerializeToElement(new { profiles = visible, active = visible.Any(p => p.Id == browser.Read().ActiveProfileId) ? browser.Read().ActiveProfileId : null });
      await c.EnsureCurrentAsync(ct);
      if (action == "create") return JsonSerializer.SerializeToElement(await browser.CreateProfileAsync(DeckCoreTools.Required(a, "name"), ct));
      var wanted = DeckCoreTools.Required(a, "profile"); var matches = visible.Where(p => p.Id == wanted || p.Name.Equals(wanted, StringComparison.OrdinalIgnoreCase)).ToArray();
      if (matches.Length != 1) throw new McpRefusal("Choose one available browser profile.");
      var id = matches[0].Id;
      switch (action)
      {
        case "rename": await browser.UpdateProfileAsync(id, name: DeckCoreTools.Required(a, "name"), cancellationToken: ct); break;
        case "avatar": await browser.UpdateProfileAsync(id, avatar: DeckCoreTools.Required(a, "avatar", empty: true), cancellationToken: ct); break;
        case "activate": await browser.ActivateProfileAsync(id, ct); break;
        case "delete": await browser.DeleteProfileAsync(id, ct); break;
      }
      return JsonSerializer.SerializeToElement(new { saved = true });
    });
  }
  // The owner application, or Hoot (the app gives only him the all-capability
  // scope). An outside key naming settings:browser stays a session-level caller.
  private static bool Manager(McpCallContext c) => c.Grant.OwnerApplication || ReferenceEquals(c.Grant.Scope, McpCallerScopes.Everything);
  private static void RequireManager(McpCallContext c)
  {
    if (!Manager(c)) throw new McpRefusal("Browser settings and windows linked to other sessions are for the person and Hoot. Use browser_open, browser_read and browser_page on this session's windows, or ask the person to Send a tab to this chat.");
    c.Require("settings", "browser");
  }
  private static void RequireOrigin(McpCallContext c, string url)
  {
    var address = BrowserModel.Address(url);
    if (address.Scheme is "http" or "https") c.Require("origins", address.GetLeftPart(UriPartial.Authority));
  }
  private static bool Allowed(McpCallContext c, BrowserTab tab) => c.Has("browser", tab.Id) || tab.SessionId is { } sid && sid == c.Grant.SessionId && c.Has("sessions", sid);
  private static BrowserTab? Resolve(McpCallContext c, JsonElement args, BrowserModel browser, bool required = true, bool bindingTarget = false)
  {
    var session = bindingTarget ? null : DeckCoreTools.Text(args, "sessionId") ?? (Manager(c) ? null : c.Grant.SessionId);
    if (session is not null) c.Require("sessions", session);
    var window = DeckCoreTools.Text(args, "window");
    var available = browser.Read().Tabs.Where(t => Allowed(c, t) && (session is null || t.SessionId == session));
    var selected = browser.Read().SelectedTabId;
    var found = window is null ? available.FirstOrDefault(t => t.Id == selected) ?? available.LastOrDefault()
      : available.FirstOrDefault(t => string.Equals(t.Window, window, StringComparison.OrdinalIgnoreCase) || t.Id == window || session is not null && string.Equals(t.SessionSlot, window, StringComparison.OrdinalIgnoreCase));
    if (found is null && (required || window is not null))
      throw new McpRefusal(window is null ? "No browser window is linked to this session yet. Open one with browser_open, or ask the person to Send a tab to this chat."
        : "Window " + window + " is not linked to this session. Use browser_windows to list this session's windows, or ask the person to Send that tab to this chat.");
    return found;
  }
}
