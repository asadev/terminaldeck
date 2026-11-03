using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Remote;

// ACK-driven preview: one outstanding image per device/window. Each rendered
// frame buys one next capture, so slow phones cannot build a pixel queue.
public sealed class PhoneBrowserWatchFeatures(
  Func<ApprovedDevice, string, bool> allowed,
  Func<string, int, int, CancellationToken, ValueTask<JsonObject>> capture,
  Func<ApprovedDevice, IReadOnlyList<(string Window, string Url, string Title)>> surfaces,
  Func<ApprovedDevice, string, string, JsonElement, CancellationToken, ValueTask<JsonObject>>? control = null) : IPhoneHostWorkspace, IDisposable
{
  private sealed class Watch(ApprovedDevice device, int width, int quality)
  {
    public readonly string Device = device.Id;
    public readonly ApprovedDevice Owner = device;
    public readonly int Width = width, Quality = quality;
    public readonly CancellationTokenSource Stop = new();
    public readonly object Gate = new();
    public int Sequence;
    public readonly Dictionary<int, double> Scales = [];
    public bool Capturing;
    public DateTimeOffset CapturedAt;
  }
  private readonly ConcurrentDictionary<(string Channel, string Window), Watch> watches = [];
  private Func<string, JsonObject, CancellationToken, ValueTask>? publish;
  private Func<string, ApprovedDevice?>? current;
  public IReadOnlyList<string> Capabilities => ["watch"];
  public bool Handles(string type) => type is "browser.watch" or "browser.unwatch" or "browser.frame.ack" or "browser.surfaces" or "browser.input" or "browser.handover.take" or "browser.handover.done";
  public bool Permits(PhoneAccess access, string type) => access == PhoneAccess.Full;
  public void Bind(Func<string, JsonObject, CancellationToken, ValueTask> publisher, Func<string, ApprovedDevice?> device) { publish = publisher; current = device; }
  public ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (!Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "Watching the PC's browser needs Full control.");
    if (type == "browser.surfaces")
    {
      var rows = new JsonArray(surfaces(device).Where(s => allowed(device, s.Window)).Take(32).Select(s => (JsonNode)new JsonObject { ["window"] = s.Window, ["title"] = s.Title, ["url"] = s.Url, ["live"] = watches.ContainsKey((channel, s.Window)) }).ToArray());
      return ValueTask.FromResult<IReadOnlyList<JsonObject>>([new JsonObject { ["t"] = "browser.surfaces.rows", ["rid"] = rid ?? Text(message, "rid"), ["surfaces"] = rows }]);
    }
    var window = Text(message, "window") ?? throw new PhoneRefusal("bad-message", "Choose a browser window.");
    var key = (channel, window);
    if (type == "browser.unwatch") { Remove(key); return ValueTask.FromResult<IReadOnlyList<JsonObject>>([]); }
    if (!allowed(device, window)) { Remove(key); throw new PhoneRefusal("unauthorized", "That browser window is not shared with this device."); }
    if (publish is null || current is null) throw new PhoneRefusal("unavailable", "This browser preview is not connected yet.");
    if (type == "browser.watch")
    {
      if (watches.Count >= 16 && !watches.ContainsKey(key)) throw new PhoneRefusal("unavailable", "Too many browser previews are already open.");
      var width = Whole(message, "maxWidth", 160, 1920); var quality = Whole(message, "quality", 10, 95);
      Remove(key); var watch = new Watch(device, width, quality); watches[key] = watch;
      _ = NextAsync(key, watch); return ValueTask.FromResult<IReadOnlyList<JsonObject>>([]);
    }
    if (type is "browser.input" or "browser.handover.take" or "browser.handover.done")
    {
      if (control is null) throw new PhoneRefusal("unavailable", "The browser input surface is not connected.");
      if (type == "browser.input" && !watches.ContainsKey(key)) throw new PhoneRefusal("unavailable", "Open this browser preview before sending input.");
      return ControlledAsync();
      async ValueTask<IReadOnlyList<JsonObject>> ControlledAsync()
      {
        var fresh = current?.Invoke(channel);
        if (fresh is null || fresh.Id != device.Id || fresh.Access != PhoneAccess.Full || !allowed(fresh, window)) throw new PhoneRefusal("unauthorized", "Browser access changed. Reopen this window with its current grant.");
        var adjusted = message;
        if (type == "browser.input")
        {
          var inputSequence = Whole(message, "seq", 0, int.MaxValue);
          var active = watches[key]; double scale;
          lock (active.Gate) if (!active.Scales.TryGetValue(inputSequence, out scale)) throw new PhoneRefusal("unavailable", "That browser picture is too old. Wait for a fresh preview.");
          adjusted = PhoneBrowserInput.ForFrame(message, scale);
        }
        var result = await control(fresh, window, type, adjusted, ct);
        if (type.StartsWith("browser.handover.", StringComparison.Ordinal) && (rid ?? Text(message, "rid")) is { } requestId) result["rid"] = requestId;
        return result.Count == 0 ? [] : [result];
      }
    }
    if (!watches.TryGetValue(key, out var existing)) return ValueTask.FromResult<IReadOnlyList<JsonObject>>([]);
    var sequence = Whole(message, "seq", 0, int.MaxValue);
    lock (existing.Gate)
    {
      if (existing.Capturing || sequence != existing.Sequence) return ValueTask.FromResult<IReadOnlyList<JsonObject>>([]);
      existing.Capturing = true;
    }
    _ = NextAsync(key, existing); return ValueTask.FromResult<IReadOnlyList<JsonObject>>([]);
  }
  private async Task NextAsync((string Channel, string Window) key, Watch watch)
  {
    try
    {
      lock (watch.Gate) watch.Capturing = true;
      var wait = TimeSpan.FromMilliseconds(250) - (DateTimeOffset.UtcNow - watch.CapturedAt);
      if (wait > TimeSpan.Zero) await Task.Delay(wait, watch.Stop.Token);
      var device = current?.Invoke(key.Channel);
      if (device is null || device.Id != watch.Device || !allowed(device, key.Window)) { Remove(key, watch); return; }
      var frame = await capture(key.Window, watch.Width, watch.Quality, watch.Stop.Token);
      device = current?.Invoke(key.Channel);
      if (device is null || device.Id != watch.Device || !allowed(device, key.Window) || watch.Stop.IsCancellationRequested) { Remove(key, watch); return; }
      frame["t"] = "browser.frame"; frame["window"] = key.Window;
      var metadata = JsonSerializer.SerializeToElement(frame); var scale = metadata.GetProperty("scale").GetDouble();
      if (!double.IsFinite(scale) || scale <= 0) throw new InvalidOperationException("The browser capture has no input geometry.");
      lock (watch.Gate)
      {
        frame["seq"] = ++watch.Sequence; watch.Scales[watch.Sequence] = scale;
        foreach (var old in watch.Scales.Keys.Order().Take(Math.Max(0, watch.Scales.Count - 8)).ToArray()) watch.Scales.Remove(old);
        watch.CapturedAt = DateTimeOffset.UtcNow; watch.Capturing = false;
      }
      await publish!(key.Channel, frame, watch.Stop.Token);
      if (control is not null)
      {
        var handover = await control(device, key.Window, "browser.handover.state", JsonSerializer.SerializeToElement(new { }), watch.Stop.Token);
        if (handover.Count > 0) await publish!(key.Channel, handover, watch.Stop.Token);
      }
    }
    catch (Exception ex) when (ex is OperationCanceledException or IOException or TimeoutException or InvalidOperationException or PhoneRefusal or ObjectDisposedException)
    {
      Remove(key, watch);
      try { if (publish is { } send) await send(key.Channel, new JsonObject { ["t"] = "error", ["code"] = "unavailable", ["message"] = "This browser preview stopped. Reopen it after the PC's page is visible." }, CancellationToken.None); }
      catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException or System.Net.WebSockets.WebSocketException) { }
    }
  }
  private void Remove((string Channel, string Window) key, Watch? expected = null)
  {
    if (!watches.TryGetValue(key, out var watch) || expected is not null && !ReferenceEquals(expected, watch)) return;
    if (((ICollection<KeyValuePair<(string Channel, string Window), Watch>>)watches).Remove(new(key, watch)))
    {
      watch.Stop.Cancel();
      if (control is not null) _ = ReleaseAsync();
      async Task ReleaseAsync()
      {
        try { await control!(watch.Owner, key.Window, "browser.release", JsonSerializer.SerializeToElement(new { }), CancellationToken.None); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { }
      }
    }
  }
  public ValueTask DisconnectedAsync(string channel) { foreach (var key in watches.Keys.Where(k => k.Channel == channel)) Remove(key); return ValueTask.CompletedTask; }
  public void Dispose() { foreach (var key in watches.Keys) Remove(key); }
  private static string? Text(JsonElement message, string field) => message.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: <= 128 } text ? text : null;
  private static int Whole(JsonElement message, string field, int min, int max) => message.TryGetProperty(field, out var value) && value.TryGetInt32(out var number) && number >= min && number <= max ? number : throw new PhoneRefusal("bad-message", "Choose a valid " + field + ".");
}
