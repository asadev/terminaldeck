using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Remote;

// BrowserModel owns the actual Windows WebViews. Composition MUST dispatch the
// whole operation to its UI thread; remote callers never get the owner MCP door.
public sealed class PhoneBrowserFeatures(BrowserModel browser,
  Func<Func<ValueTask<JsonObject>>, CancellationToken, ValueTask<JsonObject>> dispatch,
  Func<ApprovedDevice, string, bool> sessionVisible,
  Func<ApprovedDevice, IReadOnlyList<(string Id, string Title)>>? sessions = null,
  Func<string, (bool Recording, bool Loading)>? status = null,
  Func<ApprovedDevice, string, string, JsonElement, CancellationToken, ValueTask<JsonObject>>? control = null) : IPhoneHostWorkspace
{
  private static readonly HashSet<string> Types = ["browser.windows", "browser.window.open", "browser.window.go", "browser.window.act", "browser.window.bind", "browser.window.size", "browser.window.shot", "browser.window.steps", "browser.window.pick"];
  public IReadOnlyList<string> Capabilities => control is null ? ["browser.control"] : ["browser.control", "browser.thumbs"];
  public bool Handles(string type) => Types.Contains(type);
  public bool Permits(PhoneAccess access, string type) => access == PhoneAccess.Full;
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    if (!Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "Driving the PC's browser needs Full control.");
    if (!Handles(type)) throw new PhoneRefusal("bad-message", "Unknown browser action.");
    return [await dispatch(async () =>
    {
      var id = Text(message, "id"); var session = Text(message, "session");
      if (session is not null && !sessionVisible(device, session)) throw new PhoneRefusal("unknown-session", "That session is not shared with this device.");
      if (type != "browser.windows" && type != "browser.window.open")
      {
        var tab = browser.Get(id ?? "");
        if (tab.SessionId is { } owner && !sessionVisible(device, owner)) throw new PhoneRefusal("unauthorized", "That browser window is not shared with this device.");
      }
      switch (type)
      {
        case "browser.window.open":
          await browser.OpenAsync(Required(message, "url"), Bool(message, "isolated"), Text(message, "profile"), session, ct); break;
        case "browser.window.go": await browser.NavigateAsync(id!, Required(message, "url"), ct); break;
        case "browser.window.bind": await browser.AttachAsync(id!, session, ct); break;
        case "browser.window.size":
          var width = Whole(message, "width", 240, 3840); var height = Whole(message, "height", 240, 3840);
          await browser.PerformAsync(id!, BrowserPageAction.Size, JsonSerializer.SerializeToElement(new { width, height }), ct); break;
        case "browser.window.shot": case "browser.window.steps": case "browser.window.pick":
          if (control is null) throw new PhoneRefusal("unavailable", "The browser control surface is not connected.");
          var controlled = await control(device, id!, type, message, ct);
          return controlled["t"]?.GetValue<string>() == "browser.window.rows" ? Rows(device, controlled["notice"]?.GetValue<string>()) : controlled;
        case "browser.window.act":
          switch (Required(message, "action"))
          {
            case "back": await browser.PerformAsync(id!, BrowserPageAction.Back, JsonSerializer.SerializeToElement(new { }), ct); break;
            case "forward": await browser.PerformAsync(id!, BrowserPageAction.Forward, JsonSerializer.SerializeToElement(new { }), ct); break;
            case "reload": await browser.ReloadAsync(id!, cancellationToken: ct); break;
            case "close": await browser.CloseAsync(id!, ct); break;
            case "record.on": case "record.off":
              await browser.PerformAsync(id!, BrowserPageAction.Record, JsonSerializer.SerializeToElement(new { on = Text(message, "action") == "record.on" }), ct);
              if (control is not null) await control(device, id!, "browser.record.changed", message, ct); break;
            case "share": case "isolate":
              var tab = browser.Get(id!); await browser.ChangeStoreAsync(id!, tab.ProfileId, Text(message, "action") == "isolate", ct); break;
            default: throw new PhoneRefusal("bad-message", "Choose a listed browser action.");
          }
          break;
      }
      return Rows(device);
    }, ct)];
  }
  private JsonObject Rows(ApprovedDevice device, string? notice = null)
  {
    var state = browser.Read(); var rows = new JsonArray();
    foreach (var tab in state.Tabs.Where(t => t.SessionId is null || sessionVisible(device, t.SessionId)).Take(32))
    {
      var flags = status?.Invoke(tab.Id) ?? (false, false);
      rows.Add(new JsonObject { ["id"] = tab.Id, ["title"] = tab.Title, ["url"] = tab.Url, ["profile"] = tab.ProfileId, ["isolated"] = tab.Isolated, ["active"] = state.SelectedTabId == tab.Id, ["session"] = tab.SessionId, ["slot"] = tab.SessionSlot, ["recording"] = flags.Item1, ["loading"] = flags.Item2 });
    }
    var sessionRows = new JsonArray((sessions?.Invoke(device) ?? []).Where(s => sessionVisible(device, s.Id)).Take(32).Select(s => (JsonNode)new JsonObject
      { ["id"] = s.Id, ["title"] = s.Title, ["windows"] = state.Tabs.Count(t => t.SessionId == s.Id) }).ToArray());
    var result = new JsonObject { ["t"] = "browser.window.rows", ["windows"] = rows, ["sessions"] = sessionRows };
    if (notice is not null) result["notice"] = notice;
    return result;
  }
  private static string? Text(JsonElement value, string field) => value.TryGetProperty(field, out var item) && item.ValueKind == JsonValueKind.String ? item.GetString() : null;
  private static string Required(JsonElement value, string field) => Text(value, field) is { Length: > 0 and <= 8192 } text ? text : throw new PhoneRefusal("bad-message", "Missing " + field + ".");
  private static bool Bool(JsonElement value, string field) => value.TryGetProperty(field, out var item) && item.ValueKind == JsonValueKind.True;
  private static int Whole(JsonElement value, string field, int minimum, int maximum) => value.TryGetProperty(field, out var item) && item.TryGetInt32(out var number) && number >= minimum && number <= maximum ? number : throw new PhoneRefusal("bad-message", "Choose a valid " + field + ".");
}
