using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

public sealed partial class PhoneScreens
{
  private readonly ConcurrentDictionary<(string Channel, string Device), string> recordings = new();
  private readonly ConcurrentDictionary<(string Channel, string Device), CancellationTokenSource> finishing = new();
  public Func<byte[], string, string, ApprovedDevice, CancellationToken, ValueTask<string>>? DeliverRecording { get; set; }
  public bool CanRecord => host is IExtendedScreenHost { CanRecord: true } && DeliverRecording is not null;

  private async ValueTask<JsonObject> PowerAsync(string channel, ApprovedDevice device, JsonElement message, string? rid, CancellationToken ct)
  {
    if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", ControlRefused);
    if (host is not IExtendedScreenHost extended) throw new PhoneRefusal("unavailable", "Device power is not available on this PC.");
    var id = DeviceId(message);
    if (!message.TryGetProperty("on", out var on) || on.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new PhoneRefusal("bad-message", "Choose whether to start or stop the emulator.");
    await extended.PowerAsync(id, on.GetBoolean(), ct);
    return Rows(channel, rid);
  }

  private async ValueTask<IReadOnlyList<JsonObject>> RecordAsync(string channel, ApprovedDevice device, JsonElement message, string? rid, CancellationToken ct)
  {
    if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Recording a device needs Full control.");
    if (!CanRecord || host is not IExtendedScreenHost extended) throw new PhoneRefusal("unavailable", "This PC cannot record an emulator right now.");
    var id = DeviceId(message);
    if (id.StartsWith("mac:", StringComparison.Ordinal)) throw new PhoneRefusal("bad-message", "Recording is for an emulator.");
    var key = (channel, id);
    var step = PhoneHostFeatures.Text(message, "do", 12);
    if (step == "cancel")
    {
      await CancelRecordingAsync(key);
      return [new() { ["t"] = "sims.recording", ["rid"] = rid, ["id"] = id, ["state"] = "idle" }];
    }
    if (!watches.TryGetValue(key, out var watch)) throw new PhoneRefusal("unavailable", "Open the emulator first.");
    if (step == "start")
    {
      var lease = Guid.NewGuid().ToString("N");
      if (!recordings.TryAdd(key, lease)) throw new PhoneRefusal("unavailable", "This device is already recording from this phone.");
      try { await extended.RecordStartAsync(id, lease, ct); }
      catch { recordings.TryRemove(key, out _); throw; }
      if (watch.Stop.IsCancellationRequested) { recordings.TryRemove(key, out _); await extended.RecordCancelAsync(id, lease); throw new PhoneRefusal("unavailable", "The device was closed."); }
      return [new() { ["t"] = "sims.recording", ["rid"] = rid, ["id"] = id, ["state"] = "recording" }];
    }
    if (step != "stop") throw new PhoneRefusal("bad-message", "Choose start, stop or cancel for the recording.");
    var note = message.TryGetProperty("note", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() ?? "" : "";
    if (note.Length > 4_000) throw new PhoneRefusal("bad-message", "The note is too long.");
    var to = PhoneHostFeatures.Text(message, "to", 128);
    if (!recordings.TryRemove(key, out var current)) throw new PhoneRefusal("unavailable", "There is no recording to send.");
    // Finalizing/pulling can take seconds. The relay must remain free to receive a cancel/unwatch meanwhile.
    var stop = CancellationTokenSource.CreateLinkedTokenSource(ct, watch.Stop.Token);
    stop.CancelAfter(TimeSpan.FromSeconds(35));
    finishing[key] = stop;
    _ = Task.Run(async () =>
    {
      using var linked = stop;
      try
      {
        var video = await extended.RecordStopAsync(id, current, linked.Token);
        linked.Token.ThrowIfCancellationRequested();
        var latest = deviceFor(channel);
        if (latest is null || latest.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Recording needs Full control.");
        var words = await DeliverRecording!(video, note, to, latest, linked.Token);
        await send(channel, Json(new JsonObject { ["t"] = "sims.sent", ["rid"] = rid, ["ok"] = true, ["message"] = words }));
      }
      catch (OperationCanceledException) when (watch.Stop.IsCancellationRequested || !finishing.ContainsKey(key)) { }
      catch (OperationCanceledException)
      {
        await send(channel, Json(new JsonObject { ["t"] = "sims.sent", ["rid"] = rid, ["ok"] = false, ["message"] = "The recording took too long to finish. Try a shorter recording." }));
      }
      catch (Exception ex)
      {
        var words = ex.Message.Length > 400 ? ex.Message[..400] : ex.Message;
        await send(channel, Json(new JsonObject { ["t"] = "sims.sent", ["rid"] = rid, ["ok"] = false, ["message"] = words }));
      }
      finally { finishing.TryRemove(key, out _); await extended.RecordCancelAsync(id, current); }
    });
    return [];
  }

  private async ValueTask CancelRecordingAsync((string Channel, string Device) key)
  {
    if (finishing.TryRemove(key, out var stopping)) stopping.Cancel();
    if (recordings.TryRemove(key, out var lease) && host is IExtendedScreenHost extended)
      try { await extended.RecordCancelAsync(key.Device, lease); } catch (Exception ex) { System.Diagnostics.Trace.WriteLine("Discard recording: " + ex.GetType().Name); }
  }

  // This setting names the PC's desktop, not the separate Android emulator devices.
  public async Task StopPcAsync(string why)
  {
    foreach (var key in watches.Keys.Where(k => k.Device.StartsWith("mac:", StringComparison.Ordinal)).ToArray()) await StopAsync(key, why);
  }

  private string? PostWatch(Watch watch, ScreenInput input)
  {
    if (!watch.Device.StartsWith("mac:", StringComparison.Ordinal))
      return watch.Stop.IsCancellationRequested ? null : host.Post(watch.Device, input);
    // Native down and release share a gate separate from frame ACKs.
    lock (watch.InputGate)
    {
      if (watch.Stop.IsCancellationRequested) return null;
      var words = host.Post(watch.Device, input);
      if (words is not null) return words;
      var held = input switch
      {
        ScreenInput.Mouse mouse when mouse.Phase is "down" or "up" => (mouse.Button, mouse.Phase),
        ScreenInput.Click click when click.Phase is "down" or "up" => (click.Button, click.Phase),
        _ => ((string Button, string Phase)?)null,
      };
      if (held is { } state)
      {
        if (state.Phase == "down") watch.HeldButtons.Add(state.Button); else watch.HeldButtons.Remove(state.Button);
        if (state.Button == "left") watch.LeftHeld = state.Phase == "down";
      }
      return null;
    }
  }

  private readonly SemaphoreSlim inspections = new(2, 2);
  private void InspectLater(string channel, string id, string token, string rid)
  {
    _ = Task.Run(async () =>
    {
      await inspections.WaitAsync();
      try
      {
        if (!stills.ContainsKey(token)) return;
        var inspection = Inspection(id);
        if (!stills.TryGetValue(token, out var kept) || kept.Channel != channel) return;
        stills[token] = kept with { Inspection = inspection };
        await send(channel, Json(new JsonObject { ["t"] = "sims.elements", ["rid"] = rid, ["id"] = id, ["shot"] = token,
          ["elements"] = new JsonArray(inspection.Elements.Select(e => (JsonNode)e.Wire()).ToArray()), ["app"] = inspection.App, ["screen"] = inspection.Screen, ["note"] = inspection.Note }));
      }
      catch (Exception ex) { System.Diagnostics.Trace.WriteLine("Inspect phone screenshot: " + ex.GetType().Name); }
      finally { inspections.Release(); }
    });
  }

  private ScreenInspection Inspection(string id) => host is IExtendedScreenHost extended ? extended.Inspect(id) : new([], Note: "This screen does not offer element inspection.");

  private static string PickNotes(JsonElement message, ScreenInspection inspection, byte[] pixels, int width, int height)
  {
    if (!message.TryGetProperty("picks", out var picks)) return "";
    if (picks.ValueKind != JsonValueKind.Array || picks.GetArrayLength() > 30) throw new PhoneRefusal("bad-message", "Pick up to 30 elements.");
    var text = new StringBuilder(); var number = 0;
    foreach (var pick in picks.EnumerateArray())
    {
      if (!pick.TryGetInt32(out var index) || index < 0 || index >= inspection.Elements.Count) throw new PhoneRefusal("bad-message", "That picked element is not in this screenshot. Take it again.");
      var e = inspection.Elements[index];
      text.Append("\n#").Append(++number).Append(": ").Append(e.Role).Append(" · ").Append(e.Name);
      if (e.Identifier.Length > 0) text.Append(" (").Append(e.Identifier).Append(')');
      text.Append(" [").Append(e.X.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append(", ").Append(e.Y.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append(']');
      using var mark = JsonDocument.Parse(JsonSerializer.Serialize(new { c = 3, p = new[] { e.X, e.Y, e.X + e.Width, e.Y, e.X + e.Width, e.Y + e.Height, e.X, e.Y + e.Height, e.X, e.Y } }));
      Draw(pixels, width, height, mark.RootElement);
    }
    if (number == 0) return "";
    return "\n\nPicked elements from " + inspection.App + " · " + inspection.Screen + ":" + text;
  }
}
