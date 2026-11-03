using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.Platform.Windows.Phone;

public sealed partial class WindowsScreenHost : IExtendedScreenHost
{
  private readonly AndroidSdkBridge android = new();
  private readonly ConcurrentDictionary<string, (int Width, int Height)> androidSizes = new();
  public bool CanRecord => AndroidSdkBridge.Available;
  public ScreenDisplay? Device(string id)
  {
    if (!id.StartsWith("android:", StringComparison.Ordinal)) return null;
    _ = AndroidSdkBridge.Serial(id);
    var row = AndroidDeviceList.Rows().FirstOrDefault(r => r["id"]?.GetValue<string>() == id && r["state"]?.GetValue<string>() == "ready");
    if (row is null) return null;
    return new(id, row["name"]?.GetValue<string>() ?? "Android device", 0, 0, false);
  }
  public ValueTask PowerAsync(string id, bool on, CancellationToken ct) => android.PowerAsync(id, on, ct);
  public ValueTask RecordStartAsync(string id, string lease, CancellationToken ct) => android.StartRecordingAsync(id, lease, ct);
  public ValueTask<byte[]> RecordStopAsync(string id, string lease, CancellationToken ct) => android.StopRecordingAsync(id, lease, ct);
  public ValueTask RecordCancelAsync(string id, string lease) => android.CancelRecordingAsync(id, lease);

  private ScreenStill? AndroidStill(string id, out string? problem)
  {
    try
    {
      var png = android.Screenshot(id);
      using var stream = new InMemoryRandomAccessStream();
      using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(png); writer.StoreAsync().AsTask().GetAwaiter().GetResult(); }
      var decoder = BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
      if (decoder.PixelWidth is < 1 or > 8192 || decoder.PixelHeight is < 1 or > 8192 || (long)decoder.PixelWidth * decoder.PixelHeight > 16_000_000) throw new PhoneRefusal("unavailable", "The Android screen is too large to send.");
      var pixels = decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask().GetAwaiter().GetResult().DetachPixelData();
      androidSizes[id] = ((int)decoder.PixelWidth, (int)decoder.PixelHeight);
      problem = null; return new(pixels, (int)decoder.PixelWidth, (int)decoder.PixelHeight);
    }
    catch (Exception ex) { problem = "Android screen unavailable: " + ex.Message; return null; }
  }
  private ScreenPicture? AndroidCapture(string id, int maxSide, int quality, ulong? unlessHash, out string? problem)
  {
    var still = AndroidStill(id, out problem); if (still is null) return null;
    var hash = Hash(still.Bgra);
    var (width, height) = Fit(still.Width, still.Height, maxSide);
    if (hash == unlessHash) return new([], width, height, hash);
    var jpeg = EncodeJpeg(still, maxSide, quality, out width, out height);
    return new(jpeg, width, height, hash);
  }
  // stream step 2 / contract §11.7: an Android device's screen as raw pixels for the H.264 encoder (adb's screenshot,
  // decoded and scaled so the longest side is at most maxSide, both sides even), like a monitor's Grab.
  private (byte[] Bgra, int Width, int Height, ulong Hash)? AndroidGrab(string id, int maxSide, out string? problem)
  {
    try
    {
      var png = android.Screenshot(id);
      using var stream = new InMemoryRandomAccessStream();
      using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(png); writer.StoreAsync().AsTask().GetAwaiter().GetResult(); }
      var decoder = BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
      if (decoder.PixelWidth is < 2 or > 8192 || decoder.PixelHeight is < 2 or > 8192 || (long)decoder.PixelWidth * decoder.PixelHeight > 16_000_000) { problem = "The Android screen is too large to send."; return null; }
      androidSizes[id] = ((int)decoder.PixelWidth, (int)decoder.PixelHeight);
      var (width, height) = Fit((int)decoder.PixelWidth, (int)decoder.PixelHeight, maxSide);
      var transform = new BitmapTransform { ScaledWidth = (uint)width, ScaledHeight = (uint)height, InterpolationMode = BitmapInterpolationMode.Fant };
      var pixels = decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask().GetAwaiter().GetResult().DetachPixelData();
      problem = null;
      return (pixels, width, height, Hash(pixels));
    }
    catch (Exception ex) { problem = "Android screen unavailable: " + ex.Message; return null; }
  }

  public ScreenInspection Inspect(string id)
  {
    if (!id.StartsWith("mac:", StringComparison.Ordinal))
    {
      if (!androidSizes.TryGetValue(id, out var size)) { _ = AndroidStill(id, out _); if (!androidSizes.TryGetValue(id, out size)) return new([], Note: "Open the Android screen first."); }
      return android.Inspect(id, size.Width, size.Height);
    }
    using var dpi = new DpiScope();
    if (Find(id) is not { } monitor) return new([], Note: NoDisplay);
    if (Blocked() is { } blocked) return new([], Note: blocked);
    try
    {
      // A separate, bounded PowerShell process keeps a hung third-party accessibility provider away from the relay.
      // Windows PowerShell ships UIAutomationClient; no SDK, service or downloaded helper is needed.
      var script = InspectScript.Replace("__LEFT__", monitor.Left.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
        .Replace("__TOP__", monitor.Top.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
        .Replace("__WIDTH__", monitor.Width.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
        .Replace("__HEIGHT__", monitor.Height.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
      var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
      var output = AndroidSdkBridge.RunAsync(powershell, ["-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))], 200_000, 6, CancellationToken.None).AsTask().GetAwaiter().GetResult();
      using var json = JsonDocument.Parse(output);
      var root = json.RootElement;
      var elements = new List<ScreenElement>();
      if (root.TryGetProperty("elements", out var rows) && rows.ValueKind == JsonValueKind.Array)
        foreach (var e in rows.EnumerateArray().Take(250))
          elements.Add(new(e.GetProperty("r").GetString() ?? "element", e.GetProperty("n").GetString() ?? "", e.GetProperty("i").GetString() ?? "", e.GetProperty("x").GetDouble(), e.GetProperty("y").GetDouble(), e.GetProperty("w").GetDouble(), e.GetProperty("h").GetDouble()));
      return new(elements, root.TryGetProperty("app", out var a) ? a.GetString() ?? "" : "", root.TryGetProperty("screen", out var s) ? s.GetString() ?? "" : "");
    }
    catch (Exception) { return new([], Note: "Windows could not read the elements. Draw on the screenshot instead. Apps running as administrator may not allow inspection."); }
  }
  private const string InspectScript = """
    $ErrorActionPreference='Stop'
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $walk=[Windows.Automation.TreeWalker]::ControlViewWalker
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class TDInspectWindow{[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();}'
    $window=[TDInspectWindow]::GetForegroundWindow()
    if($window -eq [IntPtr]::Zero){throw 'No foreground window'}
    $root=[Windows.Automation.AutomationElement]::FromHandle($window)
    $queue=[Collections.Generic.Queue[Windows.Automation.AutomationElement]]::new()
    $queue.Enqueue($root)
    $rows=[Collections.Generic.List[object]]::new()
    $seen=0
    $screen=''
    $app=''
    $timer=[Diagnostics.Stopwatch]::StartNew()
    function clip([string]$s) { if($s.Length -gt 200){$s.Substring(0,200)}else{$s} }
    while($queue.Count -gt 0 -and $seen -lt 3000 -and $rows.Count -lt 250 -and $timer.ElapsedMilliseconds -lt 3500) {
      $node=$queue.Dequeue();$seen++
      try {
        $c=$node.Current
        $b=$c.BoundingRectangle
        if($c.IsOffscreen -or $b.IsEmpty){continue}
        $left=[Math]::Max(__LEFT__,$b.Left);$top=[Math]::Max(__TOP__,$b.Top)
        $right=[Math]::Min(__LEFT__+__WIDTH__,$b.Right);$bottom=[Math]::Min(__TOP__+__HEIGHT__,$b.Bottom)
        if($right -le $left -or $bottom -le $top){continue}
        if($c.ControlType -eq [Windows.Automation.ControlType]::Window -and !$screen){
          $screen=clip $c.Name
          try{$app=clip ([Diagnostics.Process]::GetProcessById($c.ProcessId).ProcessName)}catch{}
        }
        if(!$c.IsPassword -and ($c.Name -or $c.AutomationId) -and $c.ControlType -ne [Windows.Automation.ControlType]::Window -and $c.ControlType -ne [Windows.Automation.ControlType]::Pane){
          $rows.Add(@{r=(clip $c.LocalizedControlType);n=(clip $c.Name);i=(clip $c.AutomationId);x=(($left-__LEFT__)/__WIDTH__);y=(($top-__TOP__)/__HEIGHT__);w=(($right-$left)/__WIDTH__);h=(($bottom-$top)/__HEIGHT__)})
        }
        $child=$walk.GetFirstChild($node)
        while($null -ne $child -and $queue.Count -lt 3000){$queue.Enqueue($child);$child=$walk.GetNextSibling($child)}
      } catch {}
    }
    @{elements=@($rows.ToArray());app=$app;screen=$screen}|ConvertTo-Json -Depth 5 -Compress
    """;
}
