using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Quality;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private PhonePanelOwner[] PhoneDomainPanels() => [
    .. PhoneAdditionalPanels(), PhoneStorePanel(), PhoneReadinessPanel(), PhoneStaysFixedPanel(),
    new("memory", false, (device, request, ct) =>
    {
      var folder = PanelText(request, "path")!;
      var rows = new JsonArray(Agents.List().Where(a => PhoneProjectAllowed(device, a.ProjectId) && Projects.Get(a.ProjectId).Folders.Any(f => McpCallerScopes.Within(f, folder))).Take(100).Select(a =>
      { var memory = Agents.Seats().FirstOrDefault(s => s.SeatKey == Agents.SeatOf(a.Id).Key); return (JsonNode)new JsonObject { ["id"] = a.Id, ["title"] = a.Name, ["body"] = (memory?.Card + "\n\n" + memory?.Notes)[..Math.Min(8000, (memory?.Card + "\n\n" + memory?.Notes).Length)] }; }).ToArray());
      return ValueTask.FromResult(Panel("Agent memory", rows));
    }),
    new("goals", false, (device, request, ct) => ValueTask.FromResult(Panel("Goals", new JsonArray(Tasks.Goals().Where(g => PhoneProjectAllowed(device, g.ProjectId)).Take(200).Select(g => (JsonNode)new JsonObject { ["id"] = g.Id, ["title"] = g.Title, ["body"] = g.Description }).ToArray())))),
    new("servers", true, (device, request, ct) => ValueTask.FromResult(Panel("Servers", new JsonArray(Servers.List(PhoneServerCaller(device)).Take(200).Select(s => (JsonNode)new JsonObject { ["id"] = s.Id, ["title"] = s.Name, ["detail"] = s.User + "@" + s.Host, ["value"] = s.Access.LookOnly ? "Look only" : "Control", ["actions"] = new JsonArray(PanelAction("test", "Test connection")) }).ToArray()))),
      async (device, request, ct) => { await Servers.TestAsync(PanelText(request, "id")!, PhoneServerCaller(device), ct); }),
    PhoneDockerPanel()
  ];
  private bool PhoneProjectAllowed(ApprovedDevice device, string project) => device.Access == PhoneAccess.Full || TaskGrants.HasProject(device, project);
  private ValueTask RequirePhoneCurrentAsync(ApprovedDevice before, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var now = Remote.Trust.List().FirstOrDefault(d => d.Id == before.Id);
    if (now is null || now.Access != before.Access) throw new PhoneRefusal("unauthorized", "This device's access changed. Reconnect first.");
    return ValueTask.CompletedTask;
  }
  private ServerCaller PhoneServerCaller(ApprovedDevice device) => new("phone:" + device.Id, Owner: device.Access == PhoneAccess.Full, PairedDevice: device.Access != PhoneAccess.Full, ManageServers: device.Access == PhoneAccess.Full,
    EnsureCurrent: ct => RequirePhoneCurrentAsync(device, ct));
  private static JsonObject Panel(string title, JsonArray rows, JsonArray? actions = null) => new() { ["title"] = title, ["rows"] = rows, ["actions"] = actions ?? new JsonArray() };
  private static JsonObject PanelAction(string id, string label, params JsonObject[] fields) => new() { ["id"] = id, ["label"] = label, ["fields"] = new JsonArray(fields.Select(f => (JsonNode)f).ToArray()) };
  private static JsonObject PanelField(string id, string label, string value = "", bool required = false, string[]? choices = null) => new()
  { ["id"] = id, ["label"] = label, ["value"] = value, ["required"] = required, ["choices"] = new JsonArray((choices ?? []).Select(c => (JsonNode)JsonValue.Create(c)!).ToArray()) };
  private static Dictionary<string, string> PanelFields(JsonElement request)
  {
    if (!request.TryGetProperty("fields", out var fields)) return [];
    if (fields.ValueKind != JsonValueKind.Object || fields.EnumerateObject().Count() > 64) throw new PhoneRefusal("bad-message", "Choose bounded action fields.");
    return fields.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.ValueKind == JsonValueKind.String && p.Value.GetString() is { Length: <= 24000 } text ? text : throw new PhoneRefusal("bad-message", "Use text action fields."));
  }
  private static string? PanelText(JsonElement request, string key) => request.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
