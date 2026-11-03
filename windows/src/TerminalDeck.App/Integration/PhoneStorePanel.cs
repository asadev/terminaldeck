using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Store;
namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private PhonePanelOwner PhoneStorePanel(string name = "store", string? forcedDepartment = null) => new(name, true, (device, request, ct) =>
  {
    var rows = new JsonArray();
    foreach (var item in AppStore.Browse(department: forcedDepartment ?? (PanelText(request, "scope") is { } scope && AppStoreService.Departments.Contains(scope) ? scope : null), query: PanelText(request, "query") ?? "").Take(200))
    {
      var actions = new JsonArray(); var entry = item.Entry;
      if (Uri.TryCreate(entry.Source, UriKind.Absolute, out var uri) && uri.Scheme == "https") actions.Add(PanelAction("open-source", "Open source on this PC"));
      if (entry.Compatibility == "works" && entry.Delivery != "listing")
      {
        if (item.Installed is null || item.UpdateAvailable)
          actions.Add(PanelAction(item.Installed is null ? "install" : "update", item.Installed is null ? "Install" : "Update", StorePhoneFields(entry, PanelText(request, "path") ?? "")));
      }
      if (item.Installed is not null) { var remove = PanelAction("remove", "Remove"); remove["kind"] = "destructive"; actions.Add(remove); }
      rows.Add(new JsonObject { ["id"] = entry.Id, ["title"] = entry.Name, ["detail"] = entry.Summary, ["group"] = entry.Department, ["value"] = item.Installed is null ? entry.Version : "Installed " + item.Installed.Version, ["actions"] = actions });
    }
    var panel = Panel("Store", rows); panel["scopes"] = new JsonArray(AppStoreService.Departments.Select(d => (JsonNode)new JsonObject { ["id"] = d, ["label"] = d, ["on"] = PanelText(request, "scope") == d }).ToArray()); return ValueTask.FromResult(panel);
  }, async (device, request, ct) =>
  {
    var entry = AppStore.Browse().Single(r => r.Entry.Id == PanelText(request, "id")).Entry; var action = PanelText(request, "action")!;
    await RequirePhoneCurrentAsync(device, ct);
    if (action == "open-source")
    {
      if (!Uri.TryCreate(entry.Source, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0) throw new PhoneRefusal("bad-message", "This source address is unavailable.");
      Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); return;
    }
    var fields = PanelFields(request); var folder = fields.GetValueOrDefault("folder");
    if (!string.IsNullOrEmpty(folder)) _ = PhoneWorkspacePaths.Require(folder, new PhoneSessionsHost(this).Folders(device), device.Access == PhoneAccess.Full);
    var agents = fields.GetValueOrDefault("agents")?.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    var values = fields.Where(p => p.Key is not ("folder" or "agents")).ToDictionary(p => p.Key, p => p.Value);
    await AppStore.ChangeAsync(entry.Id, action, ct, token => RequirePhoneCurrentAsync(device, token), new StoreInstallOptions(folder, agents, values, EnsureCurrent: token => RequirePhoneCurrentAsync(device, token)));
  });
  private static JsonObject[] StorePhoneFields(StoreEntry entry, string folder)
  {
    var fields = new List<JsonObject>();
    if (entry.Delivery == "community")
    {
      var kind = entry.Manifest is { } manifest && manifest.TryGetProperty("kind", out var kindValue) ? kindValue.GetString() : null;
      fields.Add(PanelField("folder", kind == "routine" ? "Routine project folder" : "Project folder · empty for app-wide", folder, kind == "routine"));
      if (entry.Manifest is { } m && m.TryGetProperty("agents", out var agents)) fields.Add(PanelField("agents", "Coding AIs · comma-separated", string.Join(',', agents.EnumerateArray().Select(v => v.GetString()))));
    }
    if (entry.Manifest is { } source)
    {
      var inputs = source.TryGetProperty("inputs", out var direct) ? direct : source.TryGetProperty("install", out var install) && install.TryGetProperty("inputs", out var nested) ? nested : default;
      if (inputs.ValueKind == JsonValueKind.Array)
        foreach (var input in inputs.EnumerateArray().Take(32))
        {
          var key = input.GetProperty("key").GetString()!;
          var label = input.TryGetProperty("label", out var named) ? named.GetString() ?? key : key;
          var field = PanelField(key, label, required: !input.TryGetProperty("required", out var required) || required.GetBoolean());
          if (input.TryGetProperty("kind", out var inputKind) && inputKind.GetString() == "secret") field["secret"] = true;
          fields.Add(field);
        }
    }
    return fields.ToArray();
  }
}
