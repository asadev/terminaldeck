using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace TerminalDeck.Core.Remote;

// Commands are argument lists, never a PC shell. Device shell values are validated or quoted separately.
public sealed class AndroidSdkBridge
{
  private sealed record Recording(string Id, string Path, int Pid, Process Process, Task<byte[]> Errors);
  private readonly ConcurrentDictionary<string, Recording> recording = new();
  private readonly ConcurrentDictionary<string, (double X, double Y)> positions = new();
  private readonly SemaphoreSlim recordGate = new(1, 1);
  public static string? Sdk()
  {
    foreach (var path in new[] { Environment.GetEnvironmentVariable("ANDROID_HOME"), Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk") })
      if (!string.IsNullOrWhiteSpace(path) && Directory.Exists(path)) return path;
    return null;
  }
  public static bool Available => Sdk() is { } sdk && File.Exists(Path.Combine(sdk, "platform-tools", OperatingSystem.IsWindows() ? "adb.exe" : "adb"));
  private static string Adb => Sdk() is { } sdk ? Path.Combine(sdk, "platform-tools", OperatingSystem.IsWindows() ? "adb.exe" : "adb") : throw new PhoneRefusal("unavailable", "Install the Android SDK on this PC to use emulators.");
  public static bool IsSerial(string serial) => serial.Length is >= 1 and <= 132 && (char.IsAsciiLetterOrDigit(serial[0]) || serial[0] == '[') && serial.All(c => char.IsAsciiLetterOrDigit(c) || "._:-[]".Contains(c));
  public static string Serial(string id)
  {
    if (!id.StartsWith("android:", StringComparison.Ordinal) || !IsSerial(id[8..])) throw new PhoneRefusal("unavailable", "Choose a connected Android device from the list.");
    return id[8..];
  }
  private static string[] For(string id, params string[] args) => ["-s", Serial(id), .. args];
  private static Process Start(string file, string[] args)
  {
    var info = new ProcessStartInfo(file) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var arg in args) info.ArgumentList.Add(arg);
    return Process.Start(info) ?? throw new PhoneRefusal("unavailable", "The Android SDK tool did not start.");
  }
  private static async Task<byte[]> ReadBoundedAsync(Stream stream, int limit, CancellationToken ct)
  {
    using var data = new MemoryStream(); var buffer = new byte[16_384];
    int read;
    while ((read = await stream.ReadAsync(buffer, ct)) > 0)
    {
      if (data.Length + read > limit) throw new PhoneRefusal("unavailable", "The Android tool returned more data than this PC can send.");
      data.Write(buffer, 0, read);
    }
    return data.ToArray();
  }
  private static void Kill(Process process) { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } }
  public static async ValueTask<byte[]> RunAsync(string file, string[] args, int limit, int seconds, CancellationToken ct)
  {
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
    using var process = Start(file, args);
    try
    {
      var output = ReadBoundedAsync(process.StandardOutput.BaseStream, limit, timeout.Token);
      var errors = ReadBoundedAsync(process.StandardError.BaseStream, 64_000, timeout.Token);
      var exit = process.WaitForExitAsync(timeout.Token);
      // A size-limit failure must kill immediately, not wait forever for a child whose pipe stopped draining.
      var pending = new List<Task> { output, errors, exit };
      while (pending.Count > 0)
      {
        var finished = await Task.WhenAny(pending);
        await finished;
        pending.Remove(finished);
      }
      var bytes = await output; await errors;
      if (process.ExitCode != 0) throw new PhoneRefusal("unavailable", "The Android SDK could not complete the request. Check authorization and the device on the PC.");
      return bytes;
    }
    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new PhoneRefusal("unavailable", "The Android device did not answer in time."); }
    finally { Kill(process); }
  }
  public byte[] Screenshot(string id) => RunAsync(Adb, For(id, "exec-out", "screencap", "-p"), 32_000_000, 6, CancellationToken.None).AsTask().GetAwaiter().GetResult();
  public async ValueTask PowerAsync(string id, bool on, CancellationToken ct)
  {
    if (!on) { if (!Regex.IsMatch(id, "^android:emulator-[0-9]{1,6}$")) throw new PhoneRefusal("unavailable", "Only emulators can be stopped. A physical Android device stays on."); await RunAsync(Adb, For(id, "emu", "kill"), 64_000, 8, ct); return; }
    if (!Regex.IsMatch(id, "^avd:[A-Za-z0-9._-]{1,120}$")) throw new PhoneRefusal("bad-message", "Choose a stopped Android emulator to start.");
    var sdk = Sdk() ?? throw new PhoneRefusal("unavailable", "The Android SDK is not installed.");
    var file = Path.Combine(sdk, "emulator", OperatingSystem.IsWindows() ? "emulator.exe" : "emulator");
    var avds = Encoding.UTF8.GetString(await RunAsync(file, ["-list-avds"], 64_000, 6, ct)).Split('\n').Select(x => x.Trim());
    if (!avds.Contains(id[4..], StringComparer.Ordinal)) throw new PhoneRefusal("unavailable", "That emulator is no longer installed on this PC.");
    // The emulator is the requested long-lived app; stdout/stderr are not pipes that can fill after return.
    var info = new ProcessStartInfo(file) { UseShellExecute = false, CreateNoWindow = true };
    info.ArgumentList.Add("-avd"); info.ArgumentList.Add(id[4..]);
    using var process = Process.Start(info) ?? throw new PhoneRefusal("unavailable", "The emulator did not start.");
  }

  private static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
  public static string[] InputCommand(ScreenInput input, int width, int height)
  {
    string X(double x) => Math.Clamp((int)Math.Round(x * (width - 1)), 0, width - 1).ToString(CultureInfo.InvariantCulture);
    string Y(double y) => Math.Clamp((int)Math.Round(y * (height - 1)), 0, height - 1).ToString(CultureInfo.InvariantCulture);
    return input switch
    {
      ScreenInput.RightTap t => ["input", "swipe", X(t.X), Y(t.Y), X(t.X), Y(t.Y), "600"],
      ScreenInput.HardwareButton b => ["input", "keyevent", KeyCode(b.Name)],
      ScreenInput.Mouse m when m.Button == "left" => ["input", "motionevent", m.Phase switch { "down" => "DOWN", "up" => "UP", _ => "MOVE" }, X(m.X), Y(m.Y)],
      ScreenInput.Tap t when t.HoldMilliseconds >= 450 => ["input", "swipe", X(t.X), Y(t.Y), X(t.X), Y(t.Y), Math.Clamp((int)t.HoldMilliseconds.Value, 450, 5_000).ToString(CultureInfo.InvariantCulture)],
      ScreenInput.Tap t => ["input", "tap", X(t.X), Y(t.Y)],
      ScreenInput.Swipe s => ["input", "swipe", X(s.X), Y(s.Y), X(s.X2), Y(s.Y2), Math.Clamp((int)s.Milliseconds, 50, 5_000).ToString(CultureInfo.InvariantCulture)],
      ScreenInput.Scroll s => ["input", "swipe", X(s.X), Y(s.Y), X(Math.Clamp(s.X + s.Dx, 0, 1)), Y(Math.Clamp(s.Y + s.Dy, 0, 1)), "250"],
      ScreenInput.TypeText t when t.Text.All(c => c is >= ' ' and <= '~' && c != '%') => ["input", "text", Quote(t.Text.Replace(" ", "%s", StringComparison.Ordinal))],
      ScreenInput.Key k when k.Modifiers.Count == 0 => ["input", "keyevent", KeyCode(k.Name)],
      ScreenInput.Key k => ["input", "keycombination", .. k.Modifiers.Distinct().Select(m => m switch { "control" => "113", "shift" => "59", "option" => "57", "command" => "117", _ => throw new PhoneRefusal("bad-message", "Unknown modifier.") }), KeyCode(k.Name)],
      _ => throw new PhoneRefusal("unavailable", "That input is not supported by Android. Use taps, swipes, basic keys or plain English text."),
    };
  }
  private static string KeyCode(string key) => key switch
  {
    "home" => "3", "back" or "escape" => "4", "menu" => "82", "overview" => "187", "power" or "lock" => "26", "volume-up" => "24", "volume-down" => "25",
    "return" or "enter" => "66", "delete" => "67", "forward-delete" => "112", "tab" => "61", "space" => "62",
    "arrow-up" => "19", "arrow-down" => "20", "arrow-left" => "21", "arrow-right" => "22", "end" => "123", "page-up" => "92", "page-down" => "93",
    _ when key.Length == 1 && key[0] is >= 'a' and <= 'z' => (29 + key[0] - 'a').ToString(CultureInfo.InvariantCulture),
    _ when key.Length == 1 && key[0] is >= '0' and <= '9' => (7 + key[0] - '0').ToString(CultureInfo.InvariantCulture),
    _ => throw new PhoneRefusal("bad-message", "That key is not supported by Android."),
  };
  public string? Post(string id, ScreenInput input, int width, int height)
  {
    try
    {
      if (input is ScreenInput.Mouse mouse) positions[id] = (mouse.X, mouse.Y);
      if (input is ScreenInput.Click { Phase: "up", Button: "left" } && positions.TryGetValue(id, out var last)) input = new ScreenInput.Mouse("up", "left", last.X, last.Y, 1);
      if (input is ScreenInput.Rotate rotation) { RotateAsync(id, rotation.Orientation, CancellationToken.None).AsTask().GetAwaiter().GetResult(); return null; }
      if (input is ScreenInput.TypeText typed && !typed.Text.All(c => c is >= ' ' and <= '~' && c != '%'))
      {
        TypeUnicodeAsync(id, typed.Text, CancellationToken.None).AsTask().GetAwaiter().GetResult(); return null;
      }
      RunAsync(Adb, For(id, ["shell", .. InputCommand(input, width, height)]), 64_000, 7, CancellationToken.None).AsTask().GetAwaiter().GetResult(); return null;
    }
    catch (PhoneRefusal ex) { return ex.Message; }
  }

  public static int Rotation(string? orientation, int current) => orientation switch
  {
    null => (current + 1) % 4, "portrait" => 0, "landscape-left" => 1, "portrait-upside-down" => 2, "landscape-right" => 3,
    _ => throw new PhoneRefusal("bad-message", "Choose a portrait or landscape orientation.")
  };
  public async ValueTask RotateAsync(string id, string? orientation, CancellationToken ct)
  {
    var before = Encoding.UTF8.GetString(await RunAsync(Adb, For(id, "shell", "settings", "get", "system", "user_rotation"), 64_000, 6, ct)).Trim();
    var turn = Rotation(orientation, int.TryParse(before, out var current) && current is >= 0 and <= 3 ? current : 0);
    await RunAsync(Adb, For(id, "shell", "settings", "put", "system", "accelerometer_rotation", "0"), 64_000, 6, ct);
    await RunAsync(Adb, For(id, "shell", "settings", "put", "system", "user_rotation", turn.ToString(CultureInfo.InvariantCulture)), 64_000, 6, ct);
    var after = Encoding.UTF8.GetString(await RunAsync(Adb, For(id, "shell", "settings", "get", "system", "user_rotation"), 64_000, 6, ct)).Trim();
    if (after != turn.ToString(CultureInfo.InvariantCulture)) throw new PhoneRefusal("unavailable", "Android refused the rotation setting. Some apps lock their own orientation.");
  }
  public static string[] UnicodeCommand(string text, string activeIme)
  {
    if (activeIme.Trim() != "com.android.adbkeyboard/.AdbIME") throw new PhoneRefusal("unavailable", "Android SDK input supports basic Latin text. To type accents, emoji or other scripts, select an already installed ADB Keyboard on the Android device. This app does not install or change its keyboard.");
    if (text.Length is < 1 or > 2000) throw new PhoneRefusal("bad-message", "Type up to 2,000 characters at once.");
    return ["am", "broadcast", "-a", "ADB_INPUT_B64", "-p", "com.android.adbkeyboard", "--es", "msg", Convert.ToBase64String(Encoding.UTF8.GetBytes(text))];
  }
  private async ValueTask TypeUnicodeAsync(string id, string text, CancellationToken ct)
  {
    var active = Encoding.UTF8.GetString(await RunAsync(Adb, For(id, "shell", "settings", "get", "secure", "default_input_method"), 64_000, 6, ct));
    await RunAsync(Adb, For(id, ["shell", .. UnicodeCommand(text, active)]), 64_000, 7, ct);
  }

  public ScreenInspection Inspect(string id, int width, int height)
  {
    var file = "/sdcard/td-inspect-" + Guid.NewGuid().ToString("N") + ".xml";
    try
    {
      RunAsync(Adb, For(id, "shell", "uiautomator", "dump", file), 64_000, 6, CancellationToken.None).AsTask().GetAwaiter().GetResult();
      var xml = Encoding.UTF8.GetString(RunAsync(Adb, For(id, "exec-out", "cat", file), 2_000_000, 6, CancellationToken.None).AsTask().GetAwaiter().GetResult());
      return ParseInspection(xml, width, height);
    }
    catch (Exception ex) when (ex is PhoneRefusal or System.Xml.XmlException) { return new([], Note: "Android could not read the elements. Draw on the screenshot instead."); }
    finally { try { RunAsync(Adb, For(id, "shell", "rm", "-f", file), 64_000, 3, CancellationToken.None).AsTask().GetAwaiter().GetResult(); } catch (Exception) { } }
  }
  public static ScreenInspection ParseInspection(string xml, int width, int height)
  {
    using var reader = System.Xml.XmlReader.Create(new StringReader(xml), new() { DtdProcessing = System.Xml.DtdProcessing.Prohibit, MaxCharactersInDocument = 2_000_000, XmlResolver = null });
    var doc = XDocument.Load(reader); var list = new List<ScreenElement>(); var app = "";
    foreach (var node in doc.Descendants("node").Take(5_000))
    {
      var name = (string?)node.Attribute("text") ?? "";
      if (name.Length == 0) name = (string?)node.Attribute("content-desc") ?? "";
      if (name.Length == 0 && (string?)node.Attribute("clickable") != "true") continue;
      var bounds = Regex.Match((string?)node.Attribute("bounds") ?? "", @"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$");
      if (!bounds.Success || width <= 0 || height <= 0) continue;
      var values = bounds.Groups.Cast<Group>().Skip(1).Select(g => int.TryParse(g.Value, out var n) ? n : 0).ToArray();
      var left = Math.Clamp(values[0], 0, width); var top = Math.Clamp(values[1], 0, height); var right = Math.Clamp(values[2], left, width); var bottom = Math.Clamp(values[3], top, height);
      if (right <= left || bottom <= top || (string?)node.Attribute("password") == "true") continue;
      string Clip(string s) => s.Length > 200 ? s[..200] : s;
      app = Clip((string?)node.Attribute("package") ?? app);
      list.Add(new(Clip((string?)node.Attribute("class") ?? "element"), Clip(name), Clip((string?)node.Attribute("resource-id") ?? ""), left / (double)width, top / (double)height, (right - left) / (double)width, (bottom - top) / (double)height));
      if (list.Count >= 250) break;
    }
    return new(list, app);
  }

  public async ValueTask StartRecordingAsync(string id, string lease, CancellationToken ct)
  {
    await recordGate.WaitAsync(ct);
    try
    {
      if (recording.Count >= 2 || recording.Values.Any(r => r.Id == id)) throw new PhoneRefusal("unavailable", "That emulator is already recording, or this PC has two recordings open.");
      _ = Serial(id);
      var path = "/sdcard/td-record-" + lease + ".mp4";
      var process = Start(Adb, For(id, "shell", "echo $$; exec screenrecord --time-limit 120 --bit-rate 2000000 " + path));
      try
      {
        var errors = ReadBoundedAsync(process.StandardError.BaseStream, 64_000, CancellationToken.None);
        var pidText = await process.StandardOutput.ReadLineAsync(ct).AsTask().WaitAsync(TimeSpan.FromSeconds(6), ct);
        if (!int.TryParse(pidText, out var pid) || pid <= 1) throw new PhoneRefusal("unavailable", "Android did not start the recording.");
        var item = new Recording(id, path, pid, process, errors);
        if (!recording.TryAdd(lease, item)) throw new PhoneRefusal("unavailable", "The recording could not be kept.");
      }
      catch { Kill(process); process.Dispose(); throw; }
    }
    finally { recordGate.Release(); }
  }
  public async ValueTask<byte[]> StopRecordingAsync(string id, string lease, CancellationToken ct)
  {
    if (!recording.TryGetValue(lease, out var item) || item.Id != id) throw new PhoneRefusal("unavailable", "The recording is no longer available.");
    if (!item.Process.HasExited)
      await RunAsync(Adb, For(id, "shell", "kill", "-2", item.Pid.ToString(CultureInfo.InvariantCulture)), 64_000, 5, ct);
    await item.Process.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(12), ct);
    var bytes = await RunAsync(Adb, For(id, "exec-out", "cat", item.Path), 32_000_000, 20, ct);
    if (bytes.Length < 12 || Encoding.ASCII.GetString(bytes, 4, 4) != "ftyp") throw new PhoneRefusal("unavailable", "Android did not finish a usable video. Try a shorter recording.");
    return bytes;
  }
  public async ValueTask CancelRecordingAsync(string id, string lease)
  {
    if (!recording.TryRemove(lease, out var item) || item.Id != id) return;
    try
    {
      if (!item.Process.HasExited) try { await RunAsync(Adb, For(id, "shell", "kill", "-2", item.Pid.ToString(CultureInfo.InvariantCulture)), 64_000, 4, CancellationToken.None); } catch (Exception) { }
      Kill(item.Process);
      try { await item.Errors.WaitAsync(TimeSpan.FromSeconds(2)); } catch (Exception) { }
      try { await RunAsync(Adb, For(id, "shell", "rm", "-f", item.Path), 64_000, 4, CancellationToken.None); } catch (Exception) { }
    }
    finally { item.Process.Dispose(); }
  }
}
