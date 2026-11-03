using System.Text.Json;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Compose after ui.workspace's existing registration so its session and split actions stay intact.
  private void RegisterSettingsPanelTools()
  {
    Runtime.Door.Compose("ui.workspace", SettingsPanelTool);
    Runtime.Door.Compose("remote.manage", DeviceManagementTool);
    Runtime.Door.Register("mcp.open", OpenMcpServerTool);
    Runtime.Door.Compose("mcp.callers", CallerMetadataTool);
  }

  private McpToolHandler CallerMetadataTool(McpToolHandler? previous) => async (context, args, ct) =>
  {
    var action = args.GetProperty("action").GetString();
    if (action == "list")
    {
      if (previous is null) throw new McpRefusal("App key reads are unavailable.");
      var result = await previous(context, args, ct);
      var rows = result.Deserialize<McpCallerPolicy[]>() ?? [];
      var names = new CallerConnectionFiles(dataRoot).Names(rows.Select(c => c.CallerId));
      return JsonSerializer.SerializeToElement(rows.Select(c => new { c.CallerId, Name = names[c.CallerId], c.SessionId, c.SeatId, c.Mode, c.Tools, c.Tiers, c.Resources, c.Relay, c.ServerManagement }));
    }
    if (action != "rename")
      return previous is not null ? await previous(context, args, ct) : throw new McpRefusal("That app-key action is unavailable.");
    var id = args.TryGetProperty("callerId", out var caller) ? caller.GetString() : context.Grant.CallerId;
    if (id is null || id != context.Grant.CallerId && !context.Grant.OwnerApplication) throw new McpRefusal("Another app’s key must be changed by the owner.");
    if (!args.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String) throw new McpRefusal("Enter the app’s new name.");
    if (!Runtime.CallerAuthority.List().Any(c => c.CallerId == id)) throw new McpRefusal("This app connection is no longer current.");
    await context.EnsureCurrentAsync(ct);
    var saved = new CallerConnectionFiles(dataRoot).Rename(id, name.GetString() ?? "");
    await settings.RenderAsync();
    return JsonSerializer.SerializeToElement(new { callerId = id, name = saved, renamed = true });
  };

  private async ValueTask<JsonElement> OpenMcpServerTool(McpCallContext context, JsonElement args, CancellationToken ct)
  {
    context.Require("settings", "workspace");
    var id = args.GetProperty("serverId").GetString() ?? throw new McpRefusal("Choose an MCP server.");
    context.Require("mcp", id);
    var section = args.TryGetProperty("section", out var tab) ? tab.GetString() : "general";
    _ = await Runtime.Mcp.SettingsAsync(id, ct);
    await context.EnsureCurrentAsync(ct);
    await settings.OpenServerAsync(id, section);
    return JsonSerializer.SerializeToElement(new { serverId = id, opened = true, section, editorCount = settings.OpenServerEditorCount });
  }

  private McpToolHandler DeviceManagementTool(McpToolHandler? previous) => async (context, args, ct) =>
  {
    var action = args.GetProperty("do").GetString();
    if (action is not ("rename" or "deny"))
      return previous is not null ? await previous(context, args, ct) : throw new McpRefusal("That remote action is unavailable.");
    context.Require("settings", "remote");
    var id = args.GetProperty("deviceId").GetString() ?? throw new McpRefusal("Choose a paired device.");
    context.Require("devices", id);
    if (context.Grant.DeviceId is not null) throw new McpRefusal("A device cannot change its own access settings.");
    await context.EnsureCurrentAsync(ct);
    if (action == "deny") return JsonSerializer.SerializeToElement(new { denied = Runtime.Remote.Trust.DenyPending(id) });
    Runtime.Remote.Trust.Rename(id, args.GetProperty("name").GetString() ?? "");
    return JsonSerializer.SerializeToElement(new { renamed = true });
  };

  private McpToolHandler SettingsPanelTool(McpToolHandler? previous) => async (context, args, ct) =>
  {
    context.Require("settings", "workspace");
    if (args.EnumerateObject().Any()) await context.EnsureCurrentAsync(ct);
    var section = args.TryGetProperty("settingsSection", out var selected) ? selected.GetString() : null;
    if (section is not null) _ = SettingsNavigation.Canonical(section);
    var presentation = args.TryGetProperty("settingsPresentation", out var shown) ? shown.GetString() : null;
    if (presentation is not null && presentation is not ("panel" or "window" or "closed" or "shortcuts")) throw new McpRefusal("Choose window, closed or shortcuts.");
    var theme = args.TryGetProperty("theme", out var appearance) ? ParseSettingsTheme(appearance.GetString() ?? "") : (Microsoft.UI.Xaml.ElementTheme?)null;
    SettingsPanelBounds? bounds = null;
    if (args.TryGetProperty("settingsBounds", out var rectangle))
    {
      if (rectangle.ValueKind != JsonValueKind.Object || !new[] { "x", "y", "width", "height" }.All(k => rectangle.TryGetProperty(k, out var v) && v.TryGetDouble(out var n) && double.IsFinite(n)))
        throw new McpRefusal("Settings bounds need finite x, y, width and height.");
      bounds = new(rectangle.GetProperty("x").GetDouble(), rectangle.GetProperty("y").GetDouble(), rectangle.GetProperty("width").GetDouble(), rectangle.GetProperty("height").GetDouble());
    }
    // The old handler still owns non-Settings workspace actions, with the same caller checks.
    var remaining = args.EnumerateObject().Where(p => p.Name is not ("settingsSection" or "settingsPresentation" or "settingsSearch" or "settingsBounds" or "theme")).ToDictionary(p => p.Name, p => p.Value.Clone());
    if (previous is not null) await previous(context, JsonSerializer.SerializeToElement(remaining), ct);
    if (bounds is not null && presentation == "closed") throw new McpRefusal("Choose either Settings bounds or closed presentation.");
    if (theme is { } nextTheme) SaveSettingsTheme(nextTheme);
    if (section is not null || presentation is "panel" or "window" or "shortcuts" || args.TryGetProperty("settingsSearch", out _))
    {
      Model.Page = ShellPage.Settings; ShowSettingsPanel();
      if (section is not null) await settingsPanel!.SelectAsync(section);
      if (args.TryGetProperty("settingsSearch", out var query)) settingsPanel!.Search(query.GetString() ?? "");
    }
    if (presentation is "panel" or "window") ShowSettingsPanel();
    else if (presentation == "closed") CloseSettingsPanel();
    else if (presentation == "shortcuts") await settingsPanel!.ShowShortcutsAsync();
    if (bounds is not null) ApplyNativeSettingsBounds(bounds);
    return JsonSerializer.SerializeToElement(new
    {
      page = Model.Page.ToString(), selected = Model.Selected?.Id, split = Model.Split.ToString(), theme = Root.RequestedTheme.ToString(),
      settingsBounds = ReadNativeSettingsBounds(),
      settings = settingsPanel?.SelectedCategory ?? "general", settingsPresentation = settingsWindow is not null ? "window" : "closed",
      settingsCategories = SettingsNavigation.Categories.Select(item => new { item.Id, item.Title }),
      settingsMatches = SettingsNavigation.Matching(settingsPanel?.SearchQuery ?? "").Select(item => item.Id),
      windows = WindowSnapshot(context), sidebar = SidebarSnapshot(context),
      settingsShortcuts = new[] { "Ctrl+F: Search Settings", "Escape: Close Settings", "Tab / Shift+Tab: Move between controls", "Arrow keys: Move through categories" }
    });
  };
}
