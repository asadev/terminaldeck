using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

public interface IPhoneMessageWorkspace : IPhoneHostWorkspace
{
  bool Handles(string type, JsonElement message);
}
public sealed record PhonePanelOwner(string Name, bool Machine, Func<ApprovedDevice, JsonElement, CancellationToken, ValueTask<JsonObject>> Read,
  Func<ApprovedDevice, JsonElement, CancellationToken, ValueTask>? Act = null);

// Actions are accepted only when the same owner currently offers them on the
// matching row. A forged old id, action or disabled button cannot call a service.
public sealed class PhonePanelRegistry(Func<ApprovedDevice, string, bool> folderAllowed, params PhonePanelOwner[] providers) : IPhoneMessageWorkspace
{
  private readonly Dictionary<string, PhonePanelOwner> owners = providers.ToDictionary(p => p.Name);
  public IReadOnlyList<string> Capabilities => ["panels", .. owners.Keys.Select(k => "panels." + k)];
  public bool Handles(string type) => type is "panel.read" or "panel.act";
  public bool Handles(string type, JsonElement message) => Handles(type) && message.TryGetProperty("panel", out var panel) && panel.ValueKind == JsonValueKind.String && owners.ContainsKey(panel.GetString()!);
  public bool Permits(PhoneAccess access, string type) => access != PhoneAccess.Hoot && (type == "panel.read" || access != PhoneAccess.Look);
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    _ = PhonePanelPagination.Cursor(message);
    if (!Permits(device.Access, type) || !Handles(type, message)) throw new PhoneRefusal("unauthorized", "This page is outside this device's access.");
    var name = message.GetProperty("panel").GetString()!; var owner = owners[name];
    var path = Text(message, "path") ?? "";
    if (owner.Machine ? device.Access != PhoneAccess.Full : !folderAllowed(device, path)) throw new PhoneRefusal("unauthorized", "This page is outside this device's current grants.");
    var result = await owner.Read(device, message, ct);
    if (type == "panel.act")
    {
      if (device.Access == PhoneAccess.Work && name is not ("tasks" or "goals")) throw new PhoneRefusal("unauthorized", "Changing this page needs Full control.");
      var action = Text(message, "action") ?? throw new PhoneRefusal("bad-message", "Choose an action."); var id = Text(message, "id");
      var actions = id is null ? result["actions"] as JsonArray : (result["rows"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault(r => r["id"]?.GetValue<string>() == id)?["actions"] as JsonArray;
      if (owner.Act is null || actions?.OfType<JsonObject>().Any(a => (a["id"]?.GetValue<string>() == action || a["action"]?.GetValue<string>() == action) && a["disabled"]?.GetValue<bool>() != true) != true)
        throw new PhoneRefusal("unauthorized", "That action is no longer offered by this page.");
      await owner.Act(device, message, ct);
      if (action is "delete" or "move" or "remove")
      {
        var redraw = JsonNode.Parse(message.GetRawText())!.AsObject(); redraw.Remove("scope"); redraw.Remove("cursor"); redraw["t"] = "panel.read";
        result = await owner.Read(device, JsonSerializer.SerializeToElement(redraw), ct); result["view"] = null;
      }
      else result = await owner.Read(device, message, ct);
    }
    result["t"] = "panel.rows"; result["panel"] = name; result["path"] = path;
    if (rid is not null) result["rid"] = rid;
    PhonePanelPagination.Apply(message, result, rid);
    return [result];
  }
  private static string? Text(JsonElement message, string key) => message.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
