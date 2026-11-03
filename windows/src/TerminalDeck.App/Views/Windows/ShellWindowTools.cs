using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private bool WindowAllowed(McpCallContext context, WorkspaceTab tab) => tab.Kind == "page" ? context.Has("settings", "workspace") : tab.Kind == "browser"
    ? context.Has("browser", tab.Subject) || browser.Core.Read().Tabs.Any(p => p.Id == tab.Subject && p.SessionId == context.Grant.SessionId && context.Has("sessions", p.SessionId!))
    : context.Has("sessions", tab.Subject);
  private object WindowSnapshot(McpCallContext context)
  {
    var visible = windowState.Tabs.Where(t => WindowAllowed(context, t)).ToArray();
    var ids = visible.Select(t => t.Id).ToHashSet();
    return new
    {
      tabs = visible,
      readState = visible.Where(tab => Model.Sessions.Any(row => row.Id == tab.Subject)).Select(tab =>
      {
        var row = Model.Sessions.Single(row => row.Id == tab.Subject); return new { windowId = tab.Id, row.Unread, status = SessionStatus.From(row.State).Label, location = WindowLocationLabel(tab), account = WindowAccountLabel(tab), accountBadge = WindowAccountBadge(tab), planUsage = "unknown", contextUsage = "unknown" };
      }),
      layouts = windowState.Layouts.Where(l => (l.Active is null || ids.Contains(l.Active)) && (l.Root?.Tabs.All(ids.Contains) ?? true) && (l.SavedSplit?.Tabs.All(ids.Contains) ?? true)),
      appWindows = visible.Select(t => t.Host).Distinct().Select(host =>
      {
        var window = host == "main" ? (Microsoft.UI.Xaml.Window)this : detached.TryGetValue(host, out var child) ? child.Window : null;
        return new { id = host, detached = host != "main", bounds = window is null ? null : new WorkspaceWindowBounds(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height, WindowScale(window)) };
      })
    };
  }
  // The matching schema is prepared alongside this file. The shared contract
  // is outside the shell lane, so that small extension awaits its owner's OK.
  private async Task ApplyWindowActionAsync(McpCallContext context, JsonElement command, CancellationToken ct)
  {
    context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct);
    string Required(string key) => command.TryGetProperty(key, out var value) && value.GetString() is { Length: > 0 } text ? text : throw new McpRefusal("Choose " + key + " from the window list.");
    string? Text(string key) => command.TryGetProperty(key, out var value) ? value.GetString() : null;
    WorkspaceTab Allowed(string key)
    {
      var tab = windowState.Get(Required(key));
      if (!WindowAllowed(context, tab)) throw new McpRefusal("This window is outside this caller's permission.");
      return tab;
    }
    var action = Required("action");
    if (action == "sidebar")
    {
      var visible = command.GetProperty("visible").GetBoolean();
      if (sidebarVisible != visible) SidebarToggle_Click(this, new()); return;
    }
    if (action == "new-browser")
    {
      var owner = Required("ownerSessionId"); context.Require("sessions", owner);
      if (!context.Grant.OwnerApplication) throw new McpRefusal("Only the owner can open a browser from the workspace tool. Use browser.open for a scoped browser.");
      context.Require("settings", "browser"); context.Require("profiles", browser.Core.Read().ActiveProfileId);
      await CreateWindowAsync(owner, "browser"); return;
    }
    var tab = Allowed("windowId");
    var ownerId = Text("ownerSessionId") ?? tab.Owner;
    if (tab.Kind != "page" && ownerId != "browser" && ownerId != "swarm") context.Require("sessions", ownerId);
    var host = Text("hostId") ?? tab.Host;
    if (host != tab.Host) throw new McpRefusal("Choose this window's current host.");
    switch (action)
    {
      case "window-bounds":
        if (windowState.Tabs.Any(t => t.Host == host && !WindowAllowed(context, t))) throw new McpRefusal("Every tab in this app window must be within this caller’s permission.");
        var window = host == "main" ? (Microsoft.UI.Xaml.Window)this : detached[host].Window;
        var requested = new WorkspaceWindowBounds(command.GetProperty("x").GetInt32(), command.GetProperty("y").GetInt32(), command.GetProperty("width").GetInt32(), command.GetProperty("height").GetInt32(), WindowScale(window));
        var fitted = requested.Fit(WindowWorkArea(requested));
        window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height)); break;
      case "focus-empty": windowState.FocusEmpty(ownerId, host, Required("emptyPaneId")); break;
      case "mark-read":
        var readRow = Model.Sessions.FirstOrDefault(row => row.Id == tab.Subject) ?? throw new McpRefusal("Choose a session tab to mark read."); readRow.MarkRead(); break;
      case "select": windowState.Select(tab.Id); FocusWindow(ownerId, tab.Id); (tab.Host == "main" ? mainSurface : detached[tab.Host].Surface).FocusInput(tab.Id); break;
      case "rename": await SaveWindowTitleAsync(tab, Required("title")); break;
      case "move": windowState.Move(tab.Id, command.GetProperty("index").GetInt32()); break;
      case "split":
        var other = Allowed("otherWindowId");
        windowState.Split(tab.Id, other.Id, command.TryGetProperty("vertical", out var vertical) && vertical.GetBoolean(), ownerId, host); break;
      case "empty-split": windowState.EmptySplit(tab.Id, command.TryGetProperty("vertical", out var emptyVertical) && emptyVertical.GetBoolean(), ownerId, host); break;
      case "fill-empty": windowState.FillEmpty(ownerId, host, Required("emptyPaneId"), tab.Id); FocusWindow(ownerId, tab.Id); (host == "main" ? mainSurface : detached[host].Surface).FocusInput(tab.Id); break;
      case "one": windowState.One(tab.Id, ownerId, host); break;
      case "restore-split":
        if (windowState.Layout(ownerId, host).SavedSplit?.Tabs.Where(id => windowState.Tabs.Any(t => t.Id == id)).Any(id => !WindowAllowed(context, windowState.Get(id))) == true) throw new McpRefusal("Every restored pane must be within this caller’s permission.");
        windowState.RestoreSplit(ownerId, host); break;
      case "move-pane":
        var moving = Allowed("otherWindowId"); windowState.MovePane(ownerId, host, tab.Id, moving.Id, Required("edge")); break;
      case "swap":
        var peer = Allowed("otherWindowId"); windowState.Swap(ownerId, host, tab.Id, peer.Id); break;
      case "close-pane":
        windowState.ClosePane(ownerId, host, tab.Id);
        if (windowState.Layout(ownerId, host).Active is { } remaining) { FocusWindow(ownerId, remaining); (host == "main" ? mainSurface : detached[host].Surface).FocusInput(remaining); } break;
      case "resize":
        var root = windowState.Layout(ownerId, host).Root;
        PaneTree? Parent(PaneTree? node) => node is null || node.Tab is not null ? null : node.First?.Tab == tab.Id || node.Second?.Tab == tab.Id ? node : Parent(node.First) ?? Parent(node.Second);
        var parent = Parent(root) ?? throw new McpRefusal("Choose a window in a split pane.");
        if (!(parent.Tabs.All(id => WindowAllowed(context, windowState.Get(id))))) throw new McpRefusal("Every resized pane must be within this caller's permission.");
        windowState.Resize(ownerId, host, parent, command.GetProperty("ratio").GetDouble()); break;
      case "close": await CloseWindowAsync(tab.Id); break;
      case "pop-out": PopTab(tab.Id); break;
      case "dock": DockTab(tab.Id); break;
      case "pop-session":
        if (tab.Kind == "page") throw new McpRefusal("Use pop-out for one page tab.");
        foreach (var member in windowState.Tabs.Where(t => t.Owner == tab.Owner)) if (!WindowAllowed(context, member)) throw new McpRefusal("Every session window must be within this caller's permission.");
        PopSession(tab.Owner); break;
      case "attach-session":
        var session = Required("sessionId"); context.Require("sessions", session);
        if (tab.Kind == "browser") throw new McpRefusal("Use browser.windows attach for a browser window.");
        windowState.Adopt(tab.Id, session); break;
      default: throw new McpRefusal("Choose a listed window action.");
    }
    RenderWindows();
  }
  private void RegisterWindowTools()
  {
    Runtime.Door.Register("windows.list", (context, _, _) =>
    { context.Require("settings", "workspace"); return ValueTask.FromResult(JsonSerializer.SerializeToElement(WindowSnapshot(context))); });
    Runtime.Door.Register("windows.pop_out", async (context, args, ct) =>
    {
      context.Require("settings", "workspace");
      var id = args.GetProperty("sessionId").GetString()!; var tab = windowState.Get(id);
      if (!WindowAllowed(context, tab)) throw new McpRefusal("This window is outside this caller's permission.");
      var destination = args.TryGetProperty("display", out var display) ? display.GetString() : null;
      if (destination is not (null or "main" or "dock")) throw new McpRefusal("Choose main to open separately, or dock to bring it back.");
      await context.EnsureCurrentAsync(ct);
      if (destination == "dock") DockTab(id); else PopTab(id);
      return JsonSerializer.SerializeToElement(WindowSnapshot(context));
    });

  }
}
