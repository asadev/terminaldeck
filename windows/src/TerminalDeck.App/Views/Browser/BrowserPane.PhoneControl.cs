using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Remote;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  public Func<byte[], string, string, ApprovedDevice, CancellationToken, ValueTask<string>>? PhoneScreenshotDelivery { get; set; }
  private string? phoneHandoverTab;
  public void SetPhoneHandoverWindow(string? id) => phoneHandoverTab = id;
  private readonly Dictionary<string, string> phoneHandovers = [];
  private readonly Dictionary<string, List<JsonObject>> phoneSteps = [];
  private readonly HashSet<string> phoneRecorders = [];
  private readonly Dictionary<string, HashSet<string>> phoneHeldMouse = [];
  private readonly Dictionary<string, Dictionary<string, JsonObject>> phoneHeldKeys = [];

  // Composition dispatches this entire operation to the UI thread and checks
  // the device's current Full grant and window ownership before each call.
  public async ValueTask<JsonObject> PhoneBrowserControlAsync(ApprovedDevice device, string id, string type, JsonElement message, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var tab = tabs.FirstOrDefault(t => t.Id == id) ?? throw new PhoneRefusal("unavailable", "That browser window closed.");
    switch (type)
    {
      case "browser.release": await ReleasePhoneInputAsync(tab); if (phoneHandovers.GetValueOrDefault(id) == device.Id) phoneHandovers.Remove(id); return new();
      case "browser.input":
        var command = PhoneBrowserInput.Command(message);
        await tab.Model.CommandAsync(command.Method, JsonSerializer.SerializeToElement(command.Arguments));
        TrackPhoneInput(id, command); return new();
      case "browser.handover.take":
        if (handover is null || (phoneHandoverTab ?? selected?.Id) != id) throw new PhoneRefusal("unavailable", "No AI is asking for help in this window.");
        if (phoneHandovers.TryGetValue(id, out var owner) && owner != device.Id) throw new PhoneRefusal("unavailable", "Another device is already helping in this window.");
        phoneHandovers[id] = device.Id; return PhoneHandoverState(id, device.Id);
      case "browser.handover.done":
        if (phoneHandovers.GetValueOrDefault(id) != device.Id || handover is null || (phoneHandoverTab ?? selected?.Id) != id) throw new PhoneRefusal("unauthorized", "Take this window's handover before finishing it.");
        if (!message.TryGetProperty("carryOn", out var carry) || carry.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new PhoneRefusal("bad-message", "Choose whether the AI should carry on.");
        handover.TrySetResult(carry.GetBoolean()); phoneHandovers.Remove(id); await ReleasePhoneInputAsync(tab);
        return new() { ["t"] = "browser.handover.state", ["window"] = id, ["asking"] = false, ["prompt"] = "", ["mine"] = false, ["taken"] = false };
      case "browser.handover.state": return PhoneHandoverState(id, device.Id);
      case "browser.record.changed": EnsurePhoneRecorder(tab); return new();
      case "browser.window.steps":
        var steps = new JsonArray();
        if (tab.Steps.Count == 0 && phoneSteps.TryGetValue(id, out var stale)) stale.Clear();
        if (phoneSteps.TryGetValue(id, out var captured)) foreach (var step in captured.Take(160)) steps.Add(step.DeepClone());
        else foreach (var detail in tab.Steps.Take(160))
        {
          // Older/local recordings have no persisted timestamps or values.
          // Zero means unavailable; never manufacture a recording time.
          var kind = detail.Contains("navigate:", StringComparison.Ordinal) ? "navigate" : detail.Contains("entry:", StringComparison.Ordinal) ? "type" : "click";
          var colon = detail.IndexOf(": ", StringComparison.Ordinal);
          var selector = colon >= 0 && kind != "navigate" ? detail[(colon + 2)..].Replace(" (value omitted)", "", StringComparison.Ordinal) : "";
          steps.Add(new JsonObject { ["at"] = 0, ["kind"] = kind, ["detail"] = detail, ["selector"] = selector });
        }
        if (tab.Steps.Count > 160) steps.Add(new JsonObject { ["at"] = 0, ["kind"] = "truncated", ["detail"] = (tab.Steps.Count - 160) + " more steps are kept on this computer." });
        return new() { ["t"] = "browser.record.rows", ["id"] = id, ["steps"] = steps };
      case "browser.window.pick":
        var picked = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = PhoneBrowserPick.Script(message), returnByValue = true });
        if (picked.TryGetProperty("exceptionDetails", out _)) throw new PhoneRefusal("unavailable", "This page could not describe the chosen element.");
        var value = picked.GetProperty("result").GetProperty("value");
        if (!value.GetProperty("found").GetBoolean()) throw new PhoneRefusal("unavailable", "The page has moved or nothing is at that spot. Pick it again from a fresh preview.");
        var result = JsonNode.Parse(value.GetRawText())!.AsObject(); result.Remove("found"); result["t"] = "browser.window.picked"; result["id"] = id; result["url"] = tab.Address; return result;
      case "browser.window.shot":
        var png = await CaptureAsync(tab); ct.ThrowIfCancellationRequested();
        if (!(message.TryGetProperty("thumb", out var isThumb) && isThumb.ValueKind == JsonValueKind.True) && message.TryGetProperty("session", out var target) && target.ValueKind == JsonValueKind.String && target.GetString() is { Length: > 0 } session)
        {
          if (PhoneScreenshotDelivery is null) throw new PhoneRefusal("unavailable", "Screenshot delivery is not connected.");
          var note = message.TryGetProperty("note", out var supplied) && supplied.ValueKind == JsonValueKind.String ? supplied.GetString() ?? "" : "";
          var delivered = await PhoneScreenshotDelivery(png, note, session, device, ct);
          return new() { ["t"] = "browser.window.rows", ["notice"] = delivered, ["windows"] = new JsonArray(), ["sessions"] = new JsonArray() };
        }
        var preview = await PhonePreviewPngAsync(png, ct);
        return new() { ["t"] = "browser.shot", ["id"] = id, ["png"] = Convert.ToBase64String(preview), ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["thumb"] = message.TryGetProperty("thumb", out var thumb) && thumb.ValueKind == JsonValueKind.True };
      default: throw new PhoneRefusal("bad-message", "Choose a supported browser control.");
    }
  }
  private JsonObject PhoneHandoverState(string id, string device) => new() { ["t"] = "browser.handover.state", ["window"] = id, ["asking"] = handover is not null && (phoneHandoverTab ?? selected?.Id) == id, ["prompt"] = handover is null || (phoneHandoverTab ?? selected?.Id) != id ? "" : HandoverPrompt.Text, ["mine"] = phoneHandovers.GetValueOrDefault(id) == device, ["taken"] = phoneHandovers.ContainsKey(id) };
  private void TrackPhoneInput(string id, BrowserInputCommand command)
  {
    var type = command.Arguments["type"]?.GetValue<string>();
    if (command.Method == "Input.dispatchMouseEvent")
    {
      if (!phoneHeldMouse.TryGetValue(id, out var held)) phoneHeldMouse[id] = held = [];
      var button = command.Arguments["button"]?.GetValue<string>() ?? "none";
      if (type == "mousePressed") held.Add(button); else if (type == "mouseReleased") held.Remove(button);
    }
    if (command.Method == "Input.dispatchKeyEvent")
    {
      if (!phoneHeldKeys.TryGetValue(id, out var held)) phoneHeldKeys[id] = held = [];
      var key = command.Arguments["key"]?.GetValue<string>() ?? "";
      if (type == "keyDown") held[key] = (JsonObject)command.Arguments.DeepClone(); else if (type == "keyUp") held.Remove(key);
    }
  }
  private async Task ReleasePhoneInputAsync(BrowserTab tab)
  {
    if (phoneHeldMouse.Remove(tab.Id, out var buttons)) foreach (var button in buttons) await ReleaseAsync("Input.dispatchMouseEvent", new { type = "mouseReleased", x = 0, y = 0, button, clickCount = 1 });
    if (phoneHeldKeys.Remove(tab.Id, out var keys)) foreach (var key in keys.Values) { key["type"] = "keyUp"; key["text"] = ""; key["modifiers"] = 0; await ReleaseAsync("Input.dispatchKeyEvent", JsonSerializer.SerializeToElement(key)); }
    await ReleaseAsync("Input.dispatchTouchEvent", new { type = "touchCancel", touchPoints = Array.Empty<object>() });
    async Task ReleaseAsync(string method, object arguments)
    {
      try { await tab.Model.CommandAsync(method, arguments); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { }
    }
  }
  private void EnsurePhoneRecorder(BrowserTab tab)
  {
    if (!phoneRecorders.Add(tab.Id)) return;
    phoneSteps[tab.Id] = tab.Steps.Select(detail =>
    {
      var kind = detail.Contains("navigate:", StringComparison.Ordinal) ? "navigate" : detail.Contains("entry:", StringComparison.Ordinal) ? "type" : "click";
      var colon = detail.IndexOf(": ", StringComparison.Ordinal);
      return new JsonObject { ["at"] = 0, ["kind"] = kind, ["detail"] = detail, ["selector"] = colon >= 0 && kind != "navigate" ? detail[(colon + 2)..].Replace(" (value omitted)", "", StringComparison.Ordinal) : "" };
    }).ToList();
    tab.View.CoreWebView2.WebMessageReceived += (_, e) =>
    {
      if (!tab.Recording || e.Source != tab.View.CoreWebView2.Source || phoneSteps[tab.Id].Count >= 200) return;
      try
      {
        using var doc = JsonDocument.Parse(e.WebMessageAsJson); var value = doc.RootElement;
        if (!value.TryGetProperty("kind", out var kind) || kind.GetString() != "td-record") return;
        var action = value.GetProperty("action").GetString(); var selector = value.GetProperty("target").GetString() ?? "";
        if (action is not ("click" or "entry") || selector.Length > 200 || selector.Any(char.IsControl)) return;
        if (phoneSteps[tab.Id].Count >= tab.Steps.Count) phoneSteps[tab.Id].Clear();
        phoneSteps[tab.Id].Add(new() { ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["kind"] = action == "entry" ? "type" : "click", ["selector"] = selector, ["detail"] = action == "entry" ? "Entry (value omitted)" : "Click " + selector });
      }
      catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException) { }
    };
    tab.View.CoreWebView2.NavigationCompleted += (_, e) =>
    {
      if (e.IsSuccess && tab.Recording && phoneSteps[tab.Id].Count < 200 && Uri.TryCreate(tab.View.CoreWebView2.Source, UriKind.Absolute, out var address))
        phoneSteps[tab.Id].Add(new() { ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["kind"] = "navigate", ["detail"] = "Navigate to " + address.GetLeftPart(UriPartial.Authority) + " (path and query omitted)" });
    };
  }
  private static async Task<byte[]> PhonePreviewPngAsync(byte[] png, CancellationToken ct)
  {
    using var source = new InMemoryRandomAccessStream();
    using (var writer = new DataWriter(source.GetOutputStreamAt(0))) { writer.WriteBytes(png); await writer.StoreAsync(); await writer.FlushAsync(); }
    var decoder = await BitmapDecoder.CreateAsync(source); using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
    var width = (uint)Math.Min(640, bitmap.PixelWidth);
    for (var attempt = 0; attempt < 8; attempt++)
    {
      ct.ThrowIfCancellationRequested(); using var output = new InMemoryRandomAccessStream();
      var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output); encoder.SetSoftwareBitmap(bitmap);
      encoder.BitmapTransform.ScaledWidth = width; encoder.BitmapTransform.ScaledHeight = (uint)Math.Max(1, Math.Round(bitmap.PixelHeight * (double)width / bitmap.PixelWidth));
      await encoder.FlushAsync();
      if (output.Size <= 44000) { var result = new byte[(int)output.Size]; using var reader = new DataReader(output.GetInputStreamAt(0)); await reader.LoadAsync((uint)result.Length); reader.ReadBytes(result); return result; }
      width = Math.Max(64, width * 3 / 4);
    }
    throw new PhoneRefusal("unavailable", "The screenshot could not fit this connection. Send it to a session instead.");
  }
}
