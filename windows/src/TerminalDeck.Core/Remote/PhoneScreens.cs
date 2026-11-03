using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace TerminalDeck.Core.Remote;

// "This PC" on the phone's Devices page (capability `sims`), on the same wire the
// phone uses for "This Mac" (BackendPhoneDevices): `sims.list` rows with ids
// `mac:<n>`, `sims.watch` → `sims.state` then `sims.video` (H.264) on the
// direct link only (contract §11.7: no pictures, no other way), a sharp keyframe
// once the screen is still,
// `sims.input` as the trackpad model (pointer/click/wheel, keys, typing),
// `sims.pointer` for a phone that draws the pointer itself, `sims.focus` when a
// text field takes the keyboard, and `sims.shot` / `sims.annotate` for Annotate.
public sealed partial class PhoneScreens : IDisposable
{
  public const int PartChars = 80_000;
  public const int ShotBudget = 60_000;
  public const int MaxWatches = 2;
  public const double StillAfterMs = 300;
  public static readonly string WatchRefused = "Watching this PC's screen needs Work or Full control. Change this phone's access on the PC: Settings › Devices › Device access.";
  public static readonly string ControlRefused = "Only a phone with Full control can click and type on this PC. Change this phone's access on the PC: Settings › Devices › Device access.";
  /// Contract §11.7: a screen goes only as H.264 on the direct link.
  public static readonly string NeedsLink = "Screens need the direct link to your PC.";
  public static readonly string CannotShow = "This screen can't be shown on the phone right now.";
  public static readonly string[] Keys = ["return", "enter", "tab", "escape", "delete", "forward-delete", "space", "arrow-up", "arrow-down",
    "arrow-left", "arrow-right", "back", "menu", "power", "volume-up", "volume-down", "home", "end", "page-up", "page-down", "select-all", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"];
  public static readonly string[] Modifiers = ["command", "option", "control", "shift"];

  public sealed record Viewer(string Phone, string Display, bool Controlling);

  private sealed class Watch(string channel, string device, string phone, string display)
  {
    public string Channel { get; } = channel;
    public string Device { get; } = device;
    public string Phone { get; } = phone;
    public string Display { get; } = display;
    public int MaxSide; public int Fps; public bool Cursor;
    public readonly CancellationTokenSource Stop = new();
    public readonly object Gate = new();
    public readonly object InputGate = new();
    public int Seq;
    public readonly Dictionary<int, long> SentAt = [];
    public SemaphoreSlim Room { get; } = new(0, int.MaxValue);
    public long ControlledAt = long.MinValue / 2;
    public bool? Focus;
    public int Applied;
    public bool Resend;
    public volatile bool LeftHeld;
    public readonly HashSet<string> HeldButtons = [];
    // stream step 2 (video): the H.264 source, and a keyframe asked (sims.key, the hand-over).
    public IScreenVideoSource? Source;
    public int KeyAsked;
    /// M5: the keyframe (or still) that went on `td.rel` and when; the next frame waits for its ack (KeyGateMs at most).
    public int KeyGate = -1;
    public long KeyGateAt;
    /// M5: deltas on `td.rt` not acked yet (a lost one breaks the phone's chain), when deltas were lost lately, and
    /// whether this watch now sends every frame on `td.rel` (a path that keeps losing deltas).
    public readonly HashSet<int> MovingSeqs = [];
    public readonly List<long> LostAt = [];
    public bool ReliableVideo;
    public Channel<(ScreenInput Input, string? Rid, int N)> Inputs { get; } = System.Threading.Channels.Channel.CreateBounded<(ScreenInput, string?, int)>(new BoundedChannelOptions(32) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
  }
  private sealed record Still(string Channel, string Device, ScreenStill Picture, ScreenInspection Inspection, long At);

  private readonly IScreenHost host;
  private readonly Func<bool> allowed;
  private readonly string refusal;
  private readonly Func<IReadOnlyList<JsonObject>> otherDevices;
  private readonly Func<byte[], string, string, ApprovedDevice, CancellationToken, ValueTask<string>> deliver;
  private readonly ConcurrentDictionary<(string Channel, string Device), Watch> watches = new();
  private readonly ConcurrentDictionary<string, Still> stills = new();
  private Func<string, byte[], ValueTask> send = (_, _) => ValueTask.CompletedTask;
  private Func<string, ApprovedDevice?> deviceFor = _ => null;
  private CancellationTokenSource? focusLoop;
  private readonly object focusGate = new();
  public event Action? ViewersChanged;

  public PhoneScreens(IScreenHost host, Func<bool> allowed, string refusal, Func<IReadOnlyList<JsonObject>> otherDevices,
    Func<byte[], string, string, ApprovedDevice, CancellationToken, ValueTask<string>> deliver)
  {
    this.host = host; this.allowed = allowed; this.refusal = refusal; this.otherDevices = otherDevices; this.deliver = deliver;
  }

  internal void Bind(Func<string, byte[], ValueTask> publish, Func<string, ApprovedDevice?> device) { send = publish; deviceFor = device; }

  private static long Now => Environment.TickCount64;
  private static bool MayWatch(ApprovedDevice device) => device.Access is PhoneAccess.Work or PhoneAccess.Full;

  public IReadOnlyList<Viewer> Viewers() => watches.Values.OrderBy(w => w.Phone).Select(w => new Viewer(w.Phone, w.Display, Now - Volatile.Read(ref w.ControlledAt) < 15_000)).ToArray();

  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    switch (type)
    {
      case "sims.list": return [Rows(channel, rid)];
      case "sims.power": return [await PowerAsync(channel, device, message, rid, ct)];
      case "sims.record": return await RecordAsync(channel, device, message, rid, ct);
      case "sims.watch": return [await WatchAsync(channel, device, message)];
      case "sims.unwatch": await StopAsync((channel, DeviceId(message)), null); return [];
      case "sims.key":
        if (watches.TryGetValue((channel, DeviceId(message)), out var asking)) Volatile.Write(ref asking.KeyAsked, 1);
        return [];
      case "sims.ack":
      {
        if (watches.TryGetValue((channel, DeviceId(message)), out var watch) && message.TryGetProperty("seq", out var seq) && seq.TryGetInt32(out var number))
        {
          bool removed; lock (watch.Gate) removed = watch.SentAt.Remove(number);
          if (removed) watch.Room.Release();
        }
        return [];
      }
      case "sims.input": Input(channel, device, message, rid); return [];
      case "sims.shot": return Shot(device, message, rid ?? "", channel);
      case "sims.annotate": return [await AnnotateAsync(channel, device, message, rid ?? "", ct)];
      default: throw new PhoneRefusal("bad-message", "unknown message type: " + type);
    }
  }

  // ---- the list --------------------------------------------------------------------------------

  private JsonObject Rows(string channel, string? rid)
  {
    var on = allowed();
    var blocked = on ? host.Blocked() : null;
    var status = blocked is null ? null : host.BlockedStatus() ?? "Not available";
    var rows = new JsonArray();
    foreach (var display in host.Displays().Take(8))
    {
      rows.Add(new JsonObject
      {
        ["id"] = display.Id, ["name"] = display.Name, ["platform"] = "mac", ["kind"] = "display", ["state"] = "ready",
        // The phone's row subtitle is `runtime` while canWatch is true, and fixed Mac words ("Needs Screen Recording on
        // the Mac") when it is false. Screen Recording is not a PC permission, so this PC keeps canWatch true and puts its
        // own short status in runtime; a tap then gets the full sentence (REQUIREMENTS 54a).
        ["runtime"] = !on ? "Off on this PC" : status ?? "Ready · " + display.PixelWidth + " × " + display.PixelHeight,
        ["canStart"] = false, ["canStop"] = false, ["canRotate"] = false,
        ["buttons"] = new JsonArray(), ["main"] = display.Main, ["canWatch"] = true, ["canControl"] = true,
        ["note"] = !on ? refusal : blocked ?? "", ["watching"] = watches.ContainsKey((channel, display.Id))
      });
    }
    foreach (var row in otherDevices().Take(100)) rows.Add(row.DeepClone());
    var frame = new JsonObject { ["t"] = "sims.rows", ["devices"] = rows };
    if (rid is not null) frame["rid"] = rid;
    return frame;
  }

  // ---- watching --------------------------------------------------------------------------------

  private static string DeviceId(JsonElement message)
  {
    var id = PhoneHostFeatures.Text(message, "id", 140);
    if (!System.Text.RegularExpressions.Regex.IsMatch(id, @"^(mac:[0-9]{1,10}|(android|avd):[A-Za-z0-9._:-]{1,120})$")) throw new PhoneRefusal("bad-message", "That device id is not usable.");
    return id;
  }

  private ScreenDisplay Display(string id)
  {
    if (!id.StartsWith("mac:", StringComparison.Ordinal)) return (host as IExtendedScreenHost)?.Device(id) ?? throw new PhoneRefusal("unavailable", "That Android device is not connected and authorized on this PC. Refresh the list.");
    return host.Displays().FirstOrDefault(d => d.Id == id) ?? throw new PhoneRefusal("unavailable", "That display is no longer connected to this PC. Pull to refresh the list.");
  }

  private ValueTask<JsonObject> WatchAsync(string channel, ApprovedDevice device, JsonElement message)
  {
    var id = DeviceId(message);
    if (!MayWatch(device)) throw new PhoneRefusal("unauthorized", WatchRefused);
    if (DeviceId(message).StartsWith("mac:", StringComparison.Ordinal) && !allowed()) throw new PhoneRefusal("unavailable", refusal);
    // Contract §11.7: H.264 on the connection's direct link, or nothing (no pictures, never another way).
    if (!WantsVideo(message) || HasLink?.Invoke(channel) != true) throw new PhoneRefusal("unavailable", NeedsLink);
    var display = Display(id);
    var maxSide = Math.Clamp(Number(message, "maxWidth") ?? 1920, 160, 2560);
    var fps = Math.Clamp(Number(message, "fps") ?? 30, 1, VideoMostFps);
    var cursor = message.TryGetProperty("cursor", out var c) && c.ValueKind == JsonValueKind.True;
    if (watches.TryGetValue((channel, id), out var current))
    {
      // Again from the same phone: the new rate, nothing restarted; the next picture is a keyframe.
      current.MaxSide = maxSide; current.Fps = fps; current.Resend = true;
      Volatile.Write(ref current.KeyAsked, 1);
      return ValueTask.FromResult(State(id, "live", ""));
    }
    if (watches.Keys.Count(k => k.Channel == channel) >= MaxWatches) throw new PhoneRefusal("unavailable", "This phone already watches two devices. Close one first.");
    // A screen this PC cannot encode ends the watch (no picture fallback).
    string? problem = null;
    var source = Video?.Open(id, Math.Min(maxSide, VideoMostSide), fps, !cursor, out problem);
    if (source is null)
    {
      Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " This PC video unavailable for " + id + ": " + (Video is null ? "no encoder" : problem));
      return ValueTask.FromResult(State(id, "ended", CannotShow));
    }
    var watch = new Watch(channel, id, device.Name, display.Name) { MaxSide = maxSide, Fps = fps, Cursor = cursor, Source = source };
    if (!watches.TryAdd((channel, id), watch)) { source.Dispose(); return ValueTask.FromResult(State(id, "live", "")); }
    _ = Task.Run(() => VideoPumpAsync(watch));
    _ = Task.Run(() => InputsAsync(watch));
    if (cursor) _ = Task.Run(() => PointerAsync(watch));
    StartFocusLoop();
    ViewersChanged?.Invoke();
    return ValueTask.FromResult(State(id, "opening", ""));
  }

  private static JsonObject State(string id, string state, string note) => new() { ["t"] = "sims.state", ["id"] = id, ["state"] = state, ["note"] = note.Length > 400 ? note[..400] : note };

  private async Task EndAsync(Watch watch, string why)
  {
    Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " This PC watch by " + watch.Phone + " ended: " + why);
    if (!watches.TryRemove((watch.Channel, watch.Device), out _)) return;
    Release(watch);
    await send(watch.Channel, Json(State(watch.Device, "ended", why)));
    ViewersChanged?.Invoke();
  }

  private async ValueTask StopAsync((string Channel, string Device) key, string? why)
  {
    if (!watches.TryRemove(key, out var watch)) return;
    Release(watch);
    if (why is not null) await send(watch.Channel, Json(State(watch.Device, "ended", why)));
    ViewersChanged?.Invoke();
  }

  private void Release(Watch watch)
  {
    watch.Inputs.Writer.TryComplete();
    watch.Stop.Cancel(); // a video pump disposes its source itself when it stops (it may be inside Next())
    _ = CancelRecordingAsync((watch.Channel, watch.Device));
    lock (watch.InputGate)
    {
      foreach (var button in watch.HeldButtons)
        try { host.Post(watch.Device, new ScreenInput.Click(button, "up")); } catch (Exception) { }
      if (watch.LeftHeld && !watch.HeldButtons.Contains("left"))
        try { host.Post(watch.Device, new ScreenInput.Click("left", "up")); } catch (Exception) { }
      watch.HeldButtons.Clear(); watch.LeftHeld = false;
    }
  }

  // Stop on the PC (the switch turned off, or Stop beside "Watched from …"): every phone is let go and told why.
  public async Task StopAllAsync(string why)
  {
    foreach (var key in watches.Keys.ToArray()) await StopAsync(key, why);
  }

  public async ValueTask ClosedAsync(string channel)
  {
    foreach (var token in stills.Where(s => s.Value.Channel == channel).Select(s => s.Key).ToArray()) stills.TryRemove(token, out _);
    foreach (var key in watches.Keys.Where(k => k.Channel == channel).ToArray()) await StopAsync(key, null);
  }

  // ---- input -----------------------------------------------------------------------------------

  private void Input(string channel, ApprovedDevice device, JsonElement message, string? rid)
  {
    var id = DeviceId(message);

    if (DeviceId(message).StartsWith("mac:", StringComparison.Ordinal) && !allowed()) throw new PhoneRefusal("unavailable", refusal);
    if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", ControlRefused);
    if (!watches.TryGetValue((channel, id), out var watch)) throw new PhoneRefusal("unavailable", "Open this PC's screen on the phone first.");
    var input = Parse(message);
    var began = Now - Volatile.Read(ref watch.ControlledAt) >= 15_000;
    Volatile.Write(ref watch.ControlledAt, Now);
    if (began) ViewersChanged?.Invoke();
    var n = message.TryGetProperty("n", out var number) && number.TryGetInt32(out var value) ? value : 0;
    if (!watch.Inputs.Writer.TryWrite((input, rid, n)))
      throw new PhoneRefusal("unavailable", "The device is still applying earlier input. Try again in a moment.");
  }

  public static ScreenInput Parse(JsonElement message)
  {
    double Unit(string key) => message.TryGetProperty(key, out var v) && v.TryGetDouble(out var d) && double.IsFinite(d) ? Math.Clamp(d, 0, 1) : throw new PhoneRefusal("bad-message", "A position must be a number.");
    double Delta(string key) => message.TryGetProperty(key, out var v) && v.TryGetDouble(out var d) && double.IsFinite(d) ? Math.Clamp(d, -1, 1) : 0;
    string? Word(string key) => message.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    switch (Word("do"))
    {
      case "mouse":
        var mousePhase = Word("phase"); var mouseButton = Word("button");
        if (mousePhase is not ("move" or "down" or "up" or "drag") || mouseButton is not ("left" or "right" or "middle"))
          throw new PhoneRefusal("bad-message", "A mouse moves, presses, releases or drags left, right or middle.");
        return new ScreenInput.Mouse(mousePhase, mouseButton, Unit("x"), Unit("y"), Math.Clamp(Number(message, "clicks") ?? 1, 1, 3));
      case "tap":
        if (message.TryGetProperty("right", out var right) && right.ValueKind == JsonValueKind.True) return new ScreenInput.RightTap(Unit("x"), Unit("y"));
        return new ScreenInput.Tap(Unit("x"), Unit("y"), message.TryGetProperty("hold", out var hold) && hold.TryGetDouble(out var ms) ? Math.Clamp(ms, 0, 5_000) : null);
      case "scroll": return new ScreenInput.Scroll(Unit("x"), Unit("y"), Delta("dx"), Delta("dy"));
      case "swipe": return new ScreenInput.Swipe(Unit("x"), Unit("y"), Unit("x2"), Unit("y2"), message.TryGetProperty("ms", out var swipe) && swipe.TryGetDouble(out var d2) ? Math.Clamp(d2, 50, 5_000) : 300);
      case "type":
        var text = Word("text");
        if (string.IsNullOrEmpty(text) || text.Length > 2_000) throw new PhoneRefusal("bad-message", "Text to type must be a short string.");
        return new ScreenInput.TypeText(text);
      case "key":
        var key = Word("key") ?? "";
        if (!Keys.Contains(key) && !System.Text.RegularExpressions.Regex.IsMatch(key, "^[a-z0-9]$")) throw new PhoneRefusal("bad-message", "That key is not one this PC can be sent.");
        var mods = message.TryGetProperty("mods", out var m) && m.ValueKind == JsonValueKind.Array
          ? m.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).Where(Modifiers.Contains).Distinct().ToArray() : [];
        return new ScreenInput.Key(key, mods);
      case "pointer": return new ScreenInput.Pointer(Delta("dx"), Delta("dy"), message.TryGetProperty("held", out var held) && held.ValueKind == JsonValueKind.True);
      case "click":
        var button = Word("button");
        if (button is not ("left" or "right" or "middle")) throw new PhoneRefusal("bad-message", "A click is left, right or middle.");
        var phase = Word("phase");
        if (phase is not (null or "down" or "up")) throw new PhoneRefusal("bad-message", "A click is pressed, let go, or both.");
        return new ScreenInput.Click(button, phase);
      case "wheel": return new ScreenInput.Wheel(Delta("dx"), Delta("dy"));
      case "button":
        var hardware = Word("button");
        if (hardware is not ("home" or "back" or "overview" or "lock" or "power" or "menu" or "volume-up" or "volume-down" or "action")) throw new PhoneRefusal("bad-message", "Choose a listed hardware button.");
        return new ScreenInput.HardwareButton(hardware);
      case "rotate":
        var orientation = Word("orientation");
        if (orientation is not (null or "portrait" or "landscape-left" or "landscape-right" or "portrait-upside-down")) throw new PhoneRefusal("bad-message", "Choose portrait or a landscape orientation.");
        return new ScreenInput.Rotate(orientation);
      default: throw new PhoneRefusal("unavailable", "That kind of input is not on Windows yet.");
    }
  }

  // Each phone's input is applied in order the moment it arrives; pointer moves that pile up while one is
  // applied are added together and applied as one (never a backlog to catch up on).
  private async Task InputsAsync(Watch watch)
  {
    var reader = watch.Inputs.Reader;
    try
    {
      while (await reader.WaitToReadAsync())
      {
        while (reader.TryRead(out var item))
        {
          var (input, rid, n) = item;
          if (watch.Stop.IsCancellationRequested) return;
          if (input is ScreenInput.Pointer move)
          {
            double dx = move.Dx, dy = move.Dy; var heldDown = move.Held;
            while (reader.TryPeek(out var next) && next.Input is ScreenInput.Pointer more)
            {
              reader.TryRead(out _); dx += more.Dx; dy += more.Dy; heldDown = more.Held; n = Math.Max(n, next.N);
            }
            input = new ScreenInput.Pointer(Math.Clamp(dx, -1, 1), Math.Clamp(dy, -1, 1), heldDown);
          }
          string? words;
          try { words = PostWatch(watch, input); }
          catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or ArgumentException) { words = "That input did not reach this PC."; }
          if (n > 0) Volatile.Write(ref watch.Applied, Math.Max(Volatile.Read(ref watch.Applied), n));
          if (words is not null && rid is not null)
            await send(watch.Channel, Json(new JsonObject { ["t"] = "error", ["code"] = "unavailable", ["message"] = words, ["rid"] = rid }));
        }
      }
    }
    catch (OperationCanceledException) { }
  }

  // Where the pointer is, for a phone that draws it itself: when it moves (by the phone or the person at the PC),
  // at most 30 a second, with the last numbered phone move applied and the shape when it changed.
  private async Task PointerAsync(Watch watch)
  {
    var ct = watch.Stop.Token; var shape = -1; (double X, double Y, int N, bool On)? last = null;
    try
    {
      while (!ct.IsCancellationRequested)
      {
        var now = host.Pointer(watch.Device, shape);
        if (now is not null)
        {
          var n = Volatile.Read(ref watch.Applied);
          var changed = last is not { } l || l.X != now.X || l.Y != now.Y || l.N != n || l.On != now.OnDisplay;
          if (changed || now.Shape is not null)
          {
            var frame = new JsonObject { ["t"] = "sims.pointer", ["id"] = watch.Device, ["x"] = Math.Round(now.X, 5), ["y"] = Math.Round(now.Y, 5), ["n"] = n };
            if (!now.OnDisplay) frame["off"] = true;
            if (now.Shape is { } cursor)
            {
              shape = cursor.Token;
              frame["img"] = Convert.ToBase64String(cursor.Png); frame["hx"] = Math.Round(cursor.HotX, 5); frame["hy"] = Math.Round(cursor.HotY, 5);
              frame["cw"] = Math.Round(cursor.Width, 5); frame["ch"] = Math.Round(cursor.Height, 5);
            }
            await send(watch.Channel, Json(frame));
            last = (now.X, now.Y, n, now.OnDisplay);
          }
        }
        await Task.Delay(33, ct);
      }
    }
    catch (OperationCanceledException) { }
  }

  // A text field on this PC took or lost the keyboard: phones that clicked or typed in the last 15 s are told,
  // so the phone's keyboard comes up where the person clicked. A phone that only watches is never told.
  private void StartFocusLoop()
  {
    CancellationToken ct;
    lock (focusGate)
    {
      if (focusLoop is not null) return;
      focusLoop = new(); ct = focusLoop.Token;
    }
    _ = Task.Run(async () =>
    {
      try
      {
        while (!ct.IsCancellationRequested)
        {
          await Task.Delay(300, ct);
          var controlling = watches.Values.Where(w => w.Device.StartsWith("mac:", StringComparison.Ordinal) && Now - Volatile.Read(ref w.ControlledAt) < 15_000).ToArray();
          if (controlling.Length == 0) { if (watches.IsEmpty) break; continue; }
          bool? text;
          try { text = host.TextFocus(); } catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { text = null; }
          if (text is not { } focused) continue;
          foreach (var watch in controlling)
          {
            if (watch.Focus == focused) continue;
            var first = watch.Focus is null; watch.Focus = focused;
            if (first && !focused) continue;
            await send(watch.Channel, Json(new JsonObject { ["t"] = "sims.focus", ["id"] = watch.Device, ["text"] = focused }));
          }
        }
      }
      catch (OperationCanceledException) { }
      finally { lock (focusGate) { focusLoop?.Dispose(); focusLoop = null; } }
    }, CancellationToken.None);
  }

  // ---- Annotate --------------------------------------------------------------------------------

  private IReadOnlyList<JsonObject> Shot(ApprovedDevice device, JsonElement message, string rid, string channel)
  {
    var id = DeviceId(message);
    if (!MayWatch(device)) throw new PhoneRefusal("unauthorized", WatchRefused);
    if (DeviceId(message).StartsWith("mac:", StringComparison.Ordinal) && !allowed()) throw new PhoneRefusal("unavailable", refusal);
    _ = Display(id);
    var still = host.Still(id, out var problem) ?? throw new PhoneRefusal("unavailable", problem ?? "This PC's screen can't be read right now.");
    var token = Guid.NewGuid().ToString("N")[..16];
    foreach (var old in stills.Where(s => Now - s.Value.At > 600_000).Select(s => s.Key).ToArray()) stills.TryRemove(old, out _);
    while (stills.Count >= 4) { var oldest = stills.OrderBy(s => s.Value.At).First().Key; stills.TryRemove(oldest, out _); }
    var inspection = new ScreenInspection([]);
    stills[token] = new(channel, id, still, inspection, Now);
    byte[] jpeg = []; int width = 0, height = 0;
    foreach (var (side, quality) in new[] { (1600, 75), (1280, 65), (1024, 55), (800, 50), (640, 40) })
    {
      jpeg = host.EncodeJpeg(still, side, quality, out width, out height);
      if (jpeg.Length <= ShotBudget) break;
    }
    if (jpeg.Length == 0 || jpeg.Length > ShotBudget) throw new PhoneRefusal("unavailable", "This PC's screen is too detailed to send as one still. Try again.");
    var answer = new List<JsonObject> { new() { ["t"] = "sims.shot", ["rid"] = rid, ["id"] = id, ["shot"] = token, ["w"] = width, ["h"] = height, ["data"] = Convert.ToBase64String(jpeg) } };
    if (message.TryGetProperty("inspect", out var inspect) && inspect.ValueKind == JsonValueKind.True)
    {
      if (host is IExtendedScreenHost) { InspectLater(channel, id, token, rid); return answer; }
      answer.Add(new() { ["t"] = "sims.elements", ["rid"] = rid, ["id"] = id, ["shot"] = token, ["elements"] = new JsonArray(inspection.Elements.Select(e => (JsonNode)e.Wire()).ToArray()), ["app"] = inspection.App, ["screen"] = inspection.Screen,
        ["note"] = inspection.Note });
    }
    return answer;
  }

  private async ValueTask<JsonObject> AnnotateAsync(string channel, ApprovedDevice device, JsonElement message, string rid, CancellationToken ct)
  {
    var token = PhoneHostFeatures.Text(message, "shot", 64);
    if (!MayWatch(device)) throw new PhoneRefusal("unauthorized", WatchRefused);
    if (DeviceId(message).StartsWith("mac:", StringComparison.Ordinal) && !allowed()) throw new PhoneRefusal("unavailable", refusal);
    if (!stills.TryGetValue(token, out var still) || still.Channel != channel || still.Device != DeviceId(message) || Now - still.At > 600_000) throw new PhoneRefusal("unavailable", "That picture is no longer kept on this PC. Take it again.");
    var note = message.TryGetProperty("note", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString()! : "";
    if (note.Length > 4_000) note = note[..4_000];
    var to = PhoneHostFeatures.Text(message, "to", 128);
    var pixels = (byte[])still.Picture.Bgra.Clone();
    if (message.TryGetProperty("marks", out var marks) && marks.ValueKind == JsonValueKind.Array)
      foreach (var mark in marks.EnumerateArray().Take(80)) Draw(pixels, still.Picture.Width, still.Picture.Height, mark);
    note += PickNotes(message, still.Inspection, pixels, still.Picture.Width, still.Picture.Height);
    var png = host.EncodePng(new ScreenStill(pixels, still.Picture.Width, still.Picture.Height));
    var words = await deliver(png, note, to, device, ct);
    return new JsonObject { ["t"] = "sims.sent", ["rid"] = rid, ["ok"] = true, ["message"] = words };
  }

  private static readonly (byte R, byte G, byte B)[] Pens = [(255, 59, 48), (255, 204, 0), (52, 199, 89), (0, 122, 255), (255, 255, 255)];

  // A freehand mark drawn on the still at full size: its pen and points 0..1, as a round-ended thick line.
  public static void Draw(byte[] bgra, int width, int height, JsonElement mark)
  {
    if (mark.ValueKind != JsonValueKind.Object || !mark.TryGetProperty("p", out var points) || points.ValueKind != JsonValueKind.Array) return;
    var pen = Pens[mark.TryGetProperty("c", out var c) && c.TryGetInt32(out var index) && index >= 0 && index < Pens.Length ? index : 0];
    var values = points.EnumerateArray().Select(v => v.TryGetDouble(out var d) && double.IsFinite(d) ? Math.Clamp(d, 0, 1) : 0).Take(4_000).ToArray();
    var radius = Math.Max(2, Math.Min(width, height) / 220);
    for (var i = 0; i + 1 < values.Length; i += 2)
    {
      var (x0, y0) = (values[i] * (width - 1), values[i + 1] * (height - 1));
      var (x1, y1) = i + 3 < values.Length ? (values[i + 2] * (width - 1), values[i + 3] * (height - 1)) : (x0, y0);
      var steps = Math.Max(1, (int)Math.Ceiling(Math.Max(Math.Abs(x1 - x0), Math.Abs(y1 - y0)) / Math.Max(1, radius / 2.0)));
      for (var s = 0; s <= steps; s++)
      {
        var t = (double)s / steps;
        Dot(bgra, width, height, (int)Math.Round(x0 + (x1 - x0) * t), (int)Math.Round(y0 + (y1 - y0) * t), radius, pen);
      }
    }
  }

  private static void Dot(byte[] bgra, int width, int height, int cx, int cy, int r, (byte R, byte G, byte B) pen)
  {
    for (var y = Math.Max(0, cy - r); y <= Math.Min(height - 1, cy + r); y++)
      for (var x = Math.Max(0, cx - r); x <= Math.Min(width - 1, cx + r); x++)
      {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > r * r) continue;
        var at = (y * width + x) * 4;
        if (at + 3 >= bgra.Length) continue;
        bgra[at] = pen.B; bgra[at + 1] = pen.G; bgra[at + 2] = pen.R; bgra[at + 3] = 255;
      }
  }

  // ---- helpers ---------------------------------------------------------------------------------

  private static int? Number(JsonElement message, string key) => message.TryGetProperty(key, out var v) && v.TryGetDouble(out var d) && double.IsFinite(d) ? (int)Math.Round(d) : null;
  private static byte[] Json(JsonObject message) => JsonSerializer.SerializeToUtf8Bytes(message);

  public void Dispose()
  {
    foreach (var watch in watches.Values) Release(watch);
    watches.Clear();
    stills.Clear();
    lock (focusGate) { focusLoop?.Cancel(); }
  }
}

// Android emulators and phones on this PC, listed for the phone's Devices page when the Android SDK is installed.
// Authorized physical devices and emulators share the SDK capture and input route.
public static class AndroidDeviceList
{
  private static (long At, IReadOnlyList<JsonObject> Rows) cache = (long.MinValue / 2, []);
  private static readonly object Gate = new();
  public const string NotYet = "Connect this Android device and allow USB debugging on its screen.";

  private static int refreshing;
  // Never blocks sims.list (it runs while the relay waits): the last list now, a fresh one read in the background.
  public static IReadOnlyList<JsonObject> Rows()
  {
    IReadOnlyList<JsonObject> rows;
    long at;
    lock (Gate) { rows = cache.Rows.Select(r => (JsonObject)r.DeepClone()).ToArray(); at = cache.At; }
    if (Environment.TickCount64 - at > 30_000 && Interlocked.Exchange(ref refreshing, 1) == 0)
      _ = Task.Run(() => { try { Read(); } finally { Interlocked.Exchange(ref refreshing, 0); } });
    return rows;
  }

  private static void Read()
  {
    var sdk = Sdk();
    var rows = new List<JsonObject>();
    if (sdk is not null)
    {
      var adb = Path.Combine(sdk, "platform-tools", OperatingSystem.IsWindows() ? "adb.exe" : "adb");
      var running = new HashSet<string>(StringComparer.Ordinal);
      if (File.Exists(adb))
        foreach (var line in Run(adb, ["devices", "-l"]).Split('\n').Skip(1))
        {
          var parts = line.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
          if (parts.Length < 2) continue;
          var serial = parts[0];
          if (!AndroidSdkBridge.IsSerial(serial)) continue;
          var emulator = serial.StartsWith("emulator-", StringComparison.Ordinal);
          var name = emulator ? Run(adb, ["-s", serial, "emu", "avd", "name"]).Split('\n')[0].Trim() : "";
          if (emulator && name.Length > 0) running.Add(name);
          var model = parts.FirstOrDefault(p => p.StartsWith("model:", StringComparison.Ordinal))?[6..].Replace('_', ' ');
          rows.Add(Row("android:" + serial, name.Length > 0 ? name.Replace('_', ' ') : model ?? serial, emulator ? "emulator" : "physical",
            parts[1] switch { "device" => "ready", "offline" => "offline", "unauthorized" => "unauthorized", _ => "unknown" }));
        }
      var tool = Path.Combine(sdk, "emulator", OperatingSystem.IsWindows() ? "emulator.exe" : "emulator");
      if (File.Exists(tool))
        foreach (var avd in Run(tool, ["-list-avds"]).Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith("INFO", StringComparison.Ordinal) && !running.Contains(l)))
          if (System.Text.RegularExpressions.Regex.IsMatch(avd, "^[A-Za-z0-9._-]{1,120}$")) rows.Add(Row("avd:" + avd, avd.Replace('_', ' '), "emulator", "shutdown"));
    }
    lock (Gate) cache = (Environment.TickCount64, rows);
  }

  public static JsonObject Row(string id, string name, string kind, string state) => new()
  {
    ["id"] = id, ["name"] = name.Length > 120 ? name[..120] : name, ["platform"] = "android", ["kind"] = kind, ["state"] = state, ["runtime"] = "",
    ["canStart"] = kind == "emulator" && state == "shutdown", ["canStop"] = kind == "emulator" && state == "ready", ["canRotate"] = state == "ready",
    ["buttons"] = state == "ready" ? new JsonArray("home", "back", "overview", "lock", "volume-up", "volume-down") : new JsonArray(),
    ["canWatch"] = state == "ready", ["canControl"] = state == "ready",
    ["note"] = state == "ready" ? "" : kind == "emulator" && state == "shutdown" ? "Start this emulator to watch it." : state == "unauthorized" ? "Allow USB debugging on this Android device." : NotYet
  };

  private static string? Sdk()
  {
    foreach (var candidate in new[] { Environment.GetEnvironmentVariable("ANDROID_HOME"), Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT"),
      Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk") })
      if (!string.IsNullOrWhiteSpace(candidate) && Directory.Exists(candidate)) return candidate;
    return null;
  }

  private static string Run(string file, string[] arguments)
  {
    try
    {
      var start = new ProcessStartInfo(file) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
      foreach (var argument in arguments) start.ArgumentList.Add(argument);
      using var process = Process.Start(start);
      if (process is null) return "";
      var output = process.StandardOutput.ReadToEndAsync();
      if (!process.WaitForExit(5_000)) { try { process.Kill(true); } catch (InvalidOperationException) { } return ""; }
      return output.Wait(1_000) ? output.Result.Replace("\r", "") : "";
    }
    catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or IOException) { return ""; }
  }
}
