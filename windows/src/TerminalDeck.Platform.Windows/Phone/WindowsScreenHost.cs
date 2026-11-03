using System.Runtime.InteropServices;
using TerminalDeck.Core.Remote;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.Platform.Windows.Phone;

// "This PC" on the phone's Devices page: GDI pictures of each monitor and SendInput for taps,
// typing and the trackpad. Everything is synchronous and meant for background threads.
public sealed partial class WindowsScreenHost : IScreenHost
{
  // What the phone is told, by the real reason (1 Nov: a disconnected Remote Desktop session was reported as "may be locked").
  // Windows draws only a connected session: Remote Desktop from this same phone disconnects as soon as the phone
  // switches to Terminal Deck (seen 1 Nov: Asad's iPhone RDP, 08:28 to 08:30), so the viewer must be another device.
  public static readonly string Disconnected = "Nobody is signed in to this PC's screen as " + Environment.UserName + ". Keep a Remote Desktop window open as " + Environment.UserName + " on another device (not this phone), or sign in at the PC, then Try again.";
  public const string LockedScreen = "This PC is locked or showing its sign-in screen. Unlock it, then Try again.";
  private const string Locked = "This PC's screen could not be read.";
  private const string NoDisplay = "That display is not connected to this PC.";
  private const string Refused = "Windows refused the input (a window running as administrator, or the lock screen, is in front).";
  private const string UnknownKey = "That key is not one this PC can be sent.";
  private readonly Lock inputGate = new();
  [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  private readonly struct DpiScope : IDisposable
  {
    private readonly IntPtr previous;
    public DpiScope() { previous = SetThreadDpiAwarenessContext(new IntPtr(-4)); } // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    public void Dispose() { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
  }
  private double residualX, residualY;

  private readonly record struct Monitor(string Id, int Left, int Top, int Right, int Bottom, bool Primary)
  {
    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool Contains(int x, int y) => x >= Left && x < Right && y >= Top && y < Bottom;
  }

  public IReadOnlyList<ScreenDisplay> Displays()
  {
    // Physical pixels whatever the process DPI awareness (the manifest declares none).
    using var dpi = new DpiScope();
    try
    {
      var monitors = Monitors();
      var machine = Environment.MachineName;
      var displays = new List<ScreenDisplay>(monitors.Count);
      for (var i = 0; i < monitors.Count; i++)
        displays.Add(new ScreenDisplay(monitors[i].Id, monitors.Count > 1 ? machine + " · Display " + (i + 1) : machine, monitors[i].Width, monitors[i].Height, monitors[i].Primary));
      return displays;
    }
    catch (Exception) { return []; }
  }

  // Primary first, then left to right and top to bottom, numbered mac:1, mac:2...
  private static List<Monitor> Monitors()
  {
    var found = new List<(int Left, int Top, int Right, int Bottom, bool Primary)>();
    MonitorEnumProc callback = (monitor, _, _, _) =>
    {
      var info = new MonitorInfoEx { Size = (uint)Marshal.SizeOf<MonitorInfoEx>() };
      if (GetMonitorInfo(monitor, ref info) && info.Monitor.Right > info.Monitor.Left && info.Monitor.Bottom > info.Monitor.Top)
        found.Add((info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom, (info.Flags & MonitorInfoPrimary) != 0));
      return true;
    };
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
    GC.KeepAlive(callback);
    var ordered = found.OrderByDescending(m => m.Primary).ThenBy(m => m.Left).ThenBy(m => m.Top).ToList();
    var monitors = new List<Monitor>(ordered.Count);
    for (var i = 0; i < ordered.Count; i++)
      monitors.Add(new Monitor("mac:" + (i + 1), ordered[i].Left, ordered[i].Top, ordered[i].Right, ordered[i].Bottom, ordered[i].Primary));
    return monitors;
  }

  private static Monitor? Find(string displayId)
  {
    foreach (var monitor in Monitors())
      if (string.Equals(monitor.Id, displayId, StringComparison.Ordinal)) return monitor;
    return null;
  }

  // ---- Pictures ----

  public ScreenPicture? Capture(string displayId, int maxSide, int quality, bool drawCursor, ulong? unlessHash, out string? problem)
  {
    if (displayId.StartsWith("android:", StringComparison.Ordinal)) return AndroidCapture(displayId, maxSide, quality, unlessHash, out problem);
    // Physical pixels whatever the process DPI awareness (the manifest declares none).
    using var dpi = new DpiScope();
    problem = null;
    try
    {
      if (Find(displayId) is not { } monitor) { problem = NoDisplay; return null; }
      if (Blocked() is { } blocked) { problem = blocked; return null; }
      var (width, height) = Fit(monitor.Width, monitor.Height, maxSide);
      var pixels = Grab(monitor, drawCursor, width, height);
      if (pixels is null) { problem = Blocked() ?? Locked + " (Windows error " + Marshal.GetLastWin32Error() + ")"; return null; }
      var hash = Hash(pixels);
      if (unlessHash == hash) return new ScreenPicture([], width, height, hash);
      return new ScreenPicture(Encode(BitmapEncoder.JpegEncoderId, pixels, width, height, BitmapAlphaMode.Ignore, Math.Clamp(quality, 10, 95), null), width, height, hash);
    }
    catch (Exception ex) { problem = Locked + " (" + ex.GetType().Name + ": " + ex.Message + ")"; return null; }
  }

  /// stream step 2 (video): a monitor's (or an Android device's) raw pixels (top-down BGRA) scaled so the longest side is
  /// at most maxSide (both sides even), and their hash; null with the real reason when the screen cannot be read. `into`
  /// is reused when it is exactly a monitor picture's size (a watch passes the last one back), so a running watch
  /// allocates no pictures.
  public (byte[] Bgra, int Width, int Height, ulong Hash)? Grab(string displayId, int maxSide, bool drawCursor, out string? problem, byte[]? into = null)
  {
    if (displayId.StartsWith("android:", StringComparison.Ordinal)) return AndroidGrab(displayId, maxSide, out problem);
    using var dpi = new DpiScope();
    problem = null;
    try
    {
      if (Find(displayId) is not { } monitor) { problem = NoDisplay; return null; }
      if (Blocked() is { } blocked) { problem = blocked; return null; }
      var (width, height) = Fit(monitor.Width, monitor.Height, maxSide);
      var pixels = Grab(monitor, drawCursor, width, height, into);
      if (pixels is null) { problem = Blocked() ?? Locked + " (Windows error " + Marshal.GetLastWin32Error() + ")"; return null; }
      return (pixels, width, height, Hash(pixels));
    }
    catch (Exception ex) { problem = Locked + " (" + ex.GetType().Name + ": " + ex.Message + ")"; return null; }
  }

  public ScreenStill? Still(string displayId, out string? problem)
  {
    if (displayId.StartsWith("android:", StringComparison.Ordinal)) return AndroidStill(displayId, out problem);
    // Physical pixels whatever the process DPI awareness (the manifest declares none).
    using var dpi = new DpiScope();
    problem = null;
    try
    {
      if (Find(displayId) is not { } monitor) { problem = NoDisplay; return null; }
      if (Blocked() is { } blocked) { problem = blocked; return null; }
      var pixels = Grab(monitor, false, monitor.Width, monitor.Height);
      if (pixels is null) { problem = Blocked() ?? Locked + " (Windows error " + Marshal.GetLastWin32Error() + ")"; return null; }
      var words = MemoryMarshal.Cast<byte, uint>(pixels.AsSpan());
      for (var i = 0; i < words.Length; i++) words[i] |= 0xFF000000; // GDI leaves alpha undefined
      return new ScreenStill(pixels, monitor.Width, monitor.Height);
    }
    catch (Exception ex) { problem = Locked + " (" + ex.GetType().Name + ": " + ex.Message + ")"; return null; }
  }

  public byte[] EncodePng(ScreenStill still) =>
    Encode(BitmapEncoder.PngEncoderId, still.Bgra, still.Width, still.Height, BitmapAlphaMode.Ignore, null, null);

  public byte[] EncodeJpeg(ScreenStill still, int maxSide, int quality, out int width, out int height)
  {
    (width, height) = Fit(still.Width, still.Height, maxSide);
    var scale = width != still.Width || height != still.Height ? ((uint)width, (uint)height) : ((uint, uint)?)null;
    return Encode(BitmapEncoder.JpegEncoderId, still.Bgra, still.Width, still.Height, BitmapAlphaMode.Ignore, Math.Clamp(quality, 10, 95), scale);
  }

  // Longest side at most maxSide, both sides even.
  private static (int Width, int Height) Fit(int width, int height, int maxSide)
  {
    var limit = Math.Max(16, maxSide);
    var scale = Math.Min(1.0, (double)limit / Math.Max(width, height));
    var w = Math.Max(2, (int)Math.Round(width * scale) & ~1);
    var h = Math.Max(2, (int)Math.Round(height * scale) & ~1);
    return (w, h);
  }

  // The monitor's pixels (top-down BGRA) at width x height, or null when the screen cannot be copied.
  private static byte[]? Grab(Monitor monitor, bool drawCursor, int width, int height, byte[]? into = null)
  {
    var screen = GetDC(IntPtr.Zero);
    if (screen == IntPtr.Zero) return null;
    try
    {
      using var full = Dib.Create(screen, monitor.Width, monitor.Height);
      if (full is null) return null;
      if (!BitBlt(full.Dc, 0, 0, monitor.Width, monitor.Height, screen, monitor.Left, monitor.Top, SrcCopy | CaptureBlt)) return null;
      if (drawCursor) DrawCursor(full.Dc, monitor);
      if (width == monitor.Width && height == monitor.Height)
      {
        GdiFlush();
        return full.Read(into);
      }
      using var scaled = Dib.Create(screen, width, height);
      if (scaled is null) return null;
      SetStretchBltMode(scaled.Dc, Halftone);
      SetBrushOrgEx(scaled.Dc, 0, 0, IntPtr.Zero);
      if (!StretchBlt(scaled.Dc, 0, 0, width, height, full.Dc, 0, 0, monitor.Width, monitor.Height, SrcCopy)) return null;
      GdiFlush();
      return scaled.Read(into);
    }
    finally { ReleaseDC(IntPtr.Zero, screen); }
  }

  private static void DrawCursor(IntPtr dc, Monitor monitor)
  {
    var cursor = new CursorInfo { Size = (uint)Marshal.SizeOf<CursorInfo>() };
    if (!GetCursorInfo(ref cursor) || (cursor.Flags & CursorShowing) == 0 || cursor.Cursor == IntPtr.Zero) return;
    var (hotX, hotY, _, _) = CursorGeometry(cursor.Cursor);
    DrawIconEx(dc, cursor.ScreenX - monitor.Left - hotX, cursor.ScreenY - monitor.Top - hotY, cursor.Cursor, 0, 0, 0, IntPtr.Zero, DiNormal);
  }

  // The cursor's hot spot and size; frees the bitmaps GetIconInfo hands back.
  private static (int HotX, int HotY, int Width, int Height) CursorGeometry(IntPtr cursor)
  {
    int width = GetSystemMetrics(SmCxCursor), height = GetSystemMetrics(SmCyCursor);
    if (!GetIconInfo(cursor, out var info)) return (0, 0, Math.Max(1, width), Math.Max(1, height));
    try
    {
      if (info.Color != IntPtr.Zero && GetObject(info.Color, Marshal.SizeOf<BitmapHeader>(), out var color) != 0)
        (width, height) = (color.Width, Math.Abs(color.Height));
      else if (info.Mask != IntPtr.Zero && GetObject(info.Mask, Marshal.SizeOf<BitmapHeader>(), out var mask) != 0)
        (width, height) = (mask.Width, Math.Abs(mask.Height) / 2); // monochrome: AND mask over XOR mask
      return ((int)info.HotspotX, (int)info.HotspotY, Math.Max(1, width), Math.Max(1, height));
    }
    finally
    {
      if (info.Mask != IntPtr.Zero) DeleteObject(info.Mask);
      if (info.Color != IntPtr.Zero) DeleteObject(info.Color);
    }
  }

  // 64-bit FNV-1a over every pixel (alpha ignored), eight bytes at a time.
  private static ulong Hash(byte[] pixels)
  {
    var hash = 14695981039346656037UL;
    var words = MemoryMarshal.Cast<byte, ulong>(pixels.AsSpan());
    foreach (var word in words) hash = (hash ^ (word & 0x00FFFFFF00FFFFFFUL)) * 1099511628211UL;
    for (var i = words.Length * 8; i < pixels.Length; i++) hash = (hash ^ pixels[i]) * 1099511628211UL;
    return hash;
  }

  private static byte[] Encode(Guid encoderId, byte[] bgra, int width, int height, BitmapAlphaMode alpha, int? quality, (uint Width, uint Height)? scale)
  {
    using var stream = new InMemoryRandomAccessStream();
    BitmapEncoder encoder;
    if (quality is { } q)
    {
      var options = new BitmapPropertySet { { "ImageQuality", new BitmapTypedValue(q / 100f, global::Windows.Foundation.PropertyType.Single) } };
      encoder = BitmapEncoder.CreateAsync(encoderId, stream, options).AsTask().GetAwaiter().GetResult();
    }
    else encoder = BitmapEncoder.CreateAsync(encoderId, stream).AsTask().GetAwaiter().GetResult();
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, alpha, (uint)width, (uint)height, 96, 96, bgra);
    if (scale is { } size)
    {
      encoder.BitmapTransform.ScaledWidth = size.Width;
      encoder.BitmapTransform.ScaledHeight = size.Height;
      encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
    }
    encoder.FlushAsync().AsTask().GetAwaiter().GetResult();
    var length = (uint)stream.Size;
    var bytes = new byte[length];
    using var input = stream.GetInputStreamAt(0);
    using var reader = new DataReader(input);
    reader.LoadAsync(length).AsTask().GetAwaiter().GetResult();
    reader.ReadBytes(bytes);
    return bytes;
  }

  // Why this app's own session cannot be read now, or null when it can: a disconnected session (Windows stops
  // drawing it; seen on saba-pc 1 Nov, OpenInputDesktop and BitBlt both "access denied"), or the lock/sign-in screen.
  // An active Remote Desktop session counts as a desktop like the console.
  public string? Blocked() => Check().Sentence;
  // The row's short status line (the phone's subtitle).
  public string? BlockedStatus() => Check().Status;
  private (string? Sentence, string? Status) Check()
  {
    var reason = Reason();
    return reason == Disconnected ? (reason, "Remote Desktop disconnected") : reason == LockedScreen ? (reason, "Locked") : (null, null);
  }
  private string? Reason()
  {
    if (WTSQuerySessionInformation(IntPtr.Zero, -1, 8, out var buffer, out _))
    {
      var state = Marshal.ReadInt32(buffer); WTSFreeMemory(buffer);
      if (state == 4) return Disconnected; // WTSDisconnected
    }
    var desktop = OpenInputDesktop(0, false, DesktopReadObjects);
    if (desktop == IntPtr.Zero) return LockedScreen;
    try
    {
      var name = new char[64];
      if (GetUserObjectInformation(desktop, 2, name, name.Length * 2, out _) && new string(name).TrimEnd('\0').Equals("Winlogon", StringComparison.OrdinalIgnoreCase)) return LockedScreen;
      return null;
    }
    finally { CloseDesktop(desktop); }
  }

  // A 32bpp top-down DIB section selected into its own memory DC.
  private sealed class Dib : IDisposable
  {
    public IntPtr Dc { get; }
    private readonly IntPtr bitmap, previous, bits;
    private readonly int width, height;

    private Dib(IntPtr dc, IntPtr bitmap, IntPtr previous, IntPtr bits, int width, int height)
    {
      Dc = dc; this.bitmap = bitmap; this.previous = previous; this.bits = bits; this.width = width; this.height = height;
    }

    public static Dib? Create(IntPtr reference, int width, int height)
    {
      var dc = CreateCompatibleDC(reference);
      if (dc == IntPtr.Zero) return null;
      var header = new BitmapInfoHeader { Size = (uint)Marshal.SizeOf<BitmapInfoHeader>(), Width = width, Height = -height, Planes = 1, BitCount = 32, Compression = BiRgb };
      var bitmap = CreateDIBSection(reference, ref header, DibRgbColors, out var bits, IntPtr.Zero, 0);
      if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
      {
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        DeleteDC(dc);
        return null;
      }
      var previous = SelectObject(dc, bitmap);
      return new Dib(dc, bitmap, previous, bits, width, height);
    }

    public byte[] Read(byte[]? into = null)
    {
      var pixels = into is { } given && given.Length == width * height * 4 ? given : new byte[width * height * 4];
      Marshal.Copy(bits, pixels, 0, pixels.Length);
      return pixels;
    }

    public void Fill(byte value)
    {
      var pixels = new byte[width * height * 4];
      if (value != 0) Array.Fill(pixels, value);
      Marshal.Copy(pixels, 0, bits, pixels.Length);
    }

    public void Dispose()
    {
      if (previous != IntPtr.Zero) SelectObject(Dc, previous);
      DeleteObject(bitmap);
      DeleteDC(Dc);
    }
  }

  // ---- Pointer and focus ----

  public ScreenPointer? Pointer(string displayId, int knownShape)
  {
    // Physical pixels whatever the process DPI awareness (the manifest declares none).
    using var dpi = new DpiScope();
    try
    {
      if (Find(displayId) is not { } monitor) return null;
      var cursor = new CursorInfo { Size = (uint)Marshal.SizeOf<CursorInfo>() };
      if (!GetCursorInfo(ref cursor)) return null;
      int x = cursor.ScreenX, y = cursor.ScreenY;
      if (GetCursorPos(out var point)) (x, y) = (point.X, point.Y);
      var shareX = Math.Clamp((x - monitor.Left) / (double)monitor.Width, 0, 1);
      var shareY = Math.Clamp((y - monitor.Top) / (double)monitor.Height, 0, 1);
      if ((cursor.Flags & CursorShowing) == 0 || cursor.Cursor == IntPtr.Zero) return new ScreenPointer(shareX, shareY, false, null);
      var onDisplay = monitor.Contains(x, y);
      var token = unchecked((int)cursor.Cursor.ToInt64()) ^ 1;
      if (token == knownShape) return new ScreenPointer(shareX, shareY, onDisplay, null);
      return new ScreenPointer(shareX, shareY, onDisplay, RenderCursor(cursor.Cursor, token, monitor));
    }
    catch (Exception) { return null; }
  }

  // Draws the cursor on black and on white to recover its alpha (premultiplied BGRA), as a PNG.
  private static ScreenCursor? RenderCursor(IntPtr cursor, int token, Monitor monitor)
  {
    var (hotX, hotY, width, height) = CursorGeometry(cursor);
    var screen = GetDC(IntPtr.Zero);
    if (screen == IntPtr.Zero) return null;
    try
    {
      using var black = Dib.Create(screen, width, height);
      using var white = Dib.Create(screen, width, height);
      if (black is null || white is null) return null;
      black.Fill(0);
      white.Fill(0xFF);
      if (!DrawIconEx(black.Dc, 0, 0, cursor, width, height, 0, IntPtr.Zero, DiNormal) || !DrawIconEx(white.Dc, 0, 0, cursor, width, height, 0, IntPtr.Zero, DiNormal)) return null;
      GdiFlush();
      byte[] onBlack = black.Read(), onWhite = white.Read(), pixels = new byte[onBlack.Length];
      for (var i = 0; i < pixels.Length; i += 4)
      {
        var spread = (onWhite[i] - onBlack[i] + onWhite[i + 1] - onBlack[i + 1] + onWhite[i + 2] - onBlack[i + 2]) / 3;
        var alpha = (byte)Math.Clamp(255 - spread, 0, 255);
        pixels[i] = Math.Min(onBlack[i], alpha);
        pixels[i + 1] = Math.Min(onBlack[i + 1], alpha);
        pixels[i + 2] = Math.Min(onBlack[i + 2], alpha);
        pixels[i + 3] = alpha;
      }
      var png = Encode(BitmapEncoder.PngEncoderId, pixels, width, height, BitmapAlphaMode.Premultiplied, null, null);
      return new ScreenCursor(token, png, hotX / (double)width, hotY / (double)height, width / (double)monitor.Width, height / (double)monitor.Height);
    }
    finally { ReleaseDC(IntPtr.Zero, screen); }
  }

  public bool? TextFocus()
  {
    try
    {
      var window = GetForegroundWindow();
      if (window == IntPtr.Zero) return null;
      var thread = GetWindowThreadProcessId(window, out _);
      if (thread == 0) return null;
      var info = new GuiThreadInfo { Size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
      if (!GetGUIThreadInfo(thread, ref info)) return null;
      return info.Caret != IntPtr.Zero;
    }
    catch (Exception) { return null; }
  }

  // ---- Input ----

  public string? Post(string displayId, ScreenInput input)
  {
    if (displayId.StartsWith("android:", StringComparison.Ordinal))
    {
      if (!androidSizes.TryGetValue(displayId, out var size)) return "Open this emulator on the phone first.";
      return android.Post(displayId, input, size.Width, size.Height);
    }
    // Physical pixels whatever the process DPI awareness (the manifest declares none).
    using var dpi = new DpiScope();
    try
    {
      if (Find(displayId) is not { } monitor) return NoDisplay;
      lock (inputGate)
      {
        return input switch
        {
          ScreenInput.Mouse mouse => AbsoluteMouse(monitor, mouse),
          ScreenInput.Tap tap => tap.HoldMilliseconds >= 450 ? ClickAt(monitor, tap.X, tap.Y, MouseRightDown, MouseRightUp) : ClickAt(monitor, tap.X, tap.Y, MouseLeftDown, MouseLeftUp),
          ScreenInput.RightTap tap => ClickAt(monitor, tap.X, tap.Y, MouseRightDown, MouseRightUp),
          ScreenInput.Scroll scroll => Send([MoveTo(monitor, scroll.X, scroll.Y), .. WheelInputs(monitor, scroll.Dx, scroll.Dy)]),
          ScreenInput.Swipe swipe => Swipe(monitor, swipe),
          ScreenInput.TypeText text => TypeText(text.Text),
          ScreenInput.Key key => Key(key.Name, key.Modifiers),
          ScreenInput.Pointer pointer => MovePointer(monitor, pointer.Dx, pointer.Dy),
          ScreenInput.Click click => Click(click.Button, click.Phase),
          ScreenInput.Wheel wheel => Send(WheelInputs(monitor, wheel.Dx, wheel.Dy)),
          _ => UnknownKey,
        };
      }
    }
    catch (Exception) { return Refused; }
  }

  private static string? ClickAt(Monitor monitor, double x, double y, uint down, uint up) =>
    Send([MoveTo(monitor, x, y), Mouse(0, 0, 0, down), Mouse(0, 0, 0, up)]);

  private static string? Swipe(Monitor monitor, ScreenInput.Swipe swipe)
  {
    var milliseconds = Math.Max(0, swipe.Milliseconds);
    var steps = (int)Math.Max(6, Math.Min(60, milliseconds / 16));
    var pause = (int)Math.Max(4, Math.Min(25, milliseconds / steps));
    var problem = Send([MoveTo(monitor, swipe.X, swipe.Y), Mouse(0, 0, 0, MouseLeftDown)]);
    if (problem is not null) return problem;
    for (var step = 1; step <= steps && problem is null; step++)
    {
      Thread.Sleep(pause);
      var t = step / (double)steps;
      problem = Send([MoveTo(monitor, swipe.X + (swipe.X2 - swipe.X) * t, swipe.Y + (swipe.Y2 - swipe.Y) * t)]);
    }
    return Send([Mouse(0, 0, 0, MouseLeftUp)]) ?? problem;
  }

  private string? MovePointer(Monitor monitor, double dx, double dy)
  {
    double x, y;
    if (GetCursorPos(out var point) && monitor.Contains(point.X, point.Y)) (x, y) = (point.X, point.Y);
    else (x, y) = (monitor.Left + monitor.Width / 2, monitor.Top + monitor.Height / 2);
    // Keep the fractions so slow trackpad strokes still add up to movement.
    var targetX = x + dx * monitor.Width + residualX;
    var targetY = y + dy * monitor.Height + residualY;
    var px = (int)Math.Round(targetX);
    var py = (int)Math.Round(targetY);
    residualX = Math.Clamp(targetX - px, -1, 1);
    residualY = Math.Clamp(targetY - py, -1, 1);
    px = Math.Clamp(px, monitor.Left, monitor.Right - 1);
    py = Math.Clamp(py, monitor.Top, monitor.Bottom - 1);
    return Send([MoveToPixel(px, py)]);
  }

  private static string? Click(string button, string? phase)
  {
    (uint Down, uint Up)? flags = button.ToLowerInvariant() switch
    {
      "left" => (MouseLeftDown, MouseLeftUp),
      "right" => (MouseRightDown, MouseRightUp),
      "middle" => (MouseMiddleDown, MouseMiddleUp),
      _ => null,
    };
    if (flags is not { } f) return "That mouse button is not one this PC can press.";
    return phase?.ToLowerInvariant() switch
    {
      "down" => Send([Mouse(0, 0, 0, f.Down)]),
      "up" => Send([Mouse(0, 0, 0, f.Up)]),
      null => Send([Mouse(0, 0, 0, f.Down), Mouse(0, 0, 0, f.Up)]),
      _ => "That mouse button is not one this PC can press.",
    };
  }

  private static Input[] WheelInputs(Monitor monitor, double dx, double dy)
  {
    var inputs = new List<Input>(2);
    var vertical = (int)Math.Round(dy * monitor.Height * 1.2);
    var horizontal = (int)Math.Round(-dx * monitor.Width * 1.2);
    if (vertical != 0) inputs.Add(Mouse(0, 0, unchecked((uint)vertical), MouseWheel));
    if (horizontal != 0) inputs.Add(Mouse(0, 0, unchecked((uint)horizontal), MouseHWheel));
    return [.. inputs];
  }

  private static string? TypeText(string text)
  {
    var inputs = new List<Input>(text.Length * 2);
    for (var i = 0; i < text.Length; i++)
    {
      var c = text[i];
      if (c == '\r') { if (i + 1 < text.Length && text[i + 1] == '\n') continue; c = '\n'; }
      if (c == '\n' || c == '\t')
      {
        var vk = c == '\n' ? VkReturn : VkTab;
        inputs.Add(Keyboard(vk, 0, 0));
        inputs.Add(Keyboard(vk, 0, KeyUp));
        continue;
      }
      inputs.Add(Keyboard(0, c, KeyUnicode));
      inputs.Add(Keyboard(0, c, KeyUnicode | KeyUp));
    }
    return Send([.. inputs]);
  }

  private static string? Key(string name, IReadOnlyList<string> modifiers)
  {
    var mods = new List<ushort>();
    foreach (var modifier in modifiers)
    {
      ushort? vk = modifier.ToLowerInvariant() switch
      {
        "command" or "cmd" or "control" or "ctrl" => VkControl,
        "option" or "alt" => VkMenu,
        "shift" => VkShift,
        _ => null,
      };
      if (vk is not { } v) return UnknownKey;
      if (!mods.Contains(v)) mods.Add(v);
    }
    var lower = name.Trim().ToLowerInvariant();
    if (lower == "select-all")
    {
      if (!mods.Contains(VkControl)) mods.Add(VkControl);
      lower = "a";
    }
    if (KeyCode(lower) is not { } key) return UnknownKey;
    var inputs = new List<Input>();
    foreach (var mod in mods) inputs.Add(Keyboard(mod, 0, 0));
    var extended = key.Extended ? KeyExtended : 0u;
    inputs.Add(Keyboard(key.Vk, 0, extended));
    inputs.Add(Keyboard(key.Vk, 0, extended | KeyUp));
    for (var i = mods.Count - 1; i >= 0; i--) inputs.Add(Keyboard(mods[i], 0, KeyUp));
    return Send([.. inputs]);
  }

  private static (ushort Vk, bool Extended)? KeyCode(string name)
  {
    switch (name)
    {
      case "return": case "enter": return (VkReturn, false);
      case "tab": return (VkTab, false);
      case "escape": case "esc": return (0x1B, false);
      case "delete": case "backspace": return (0x08, false);
      case "forward-delete": return (0x2E, true);
      case "space": return (0x20, false);
      case "arrow-left": case "left": return (0x25, true);
      case "arrow-up": case "up": return (0x26, true);
      case "arrow-right": case "right": return (0x27, true);
      case "arrow-down": case "down": return (0x28, true);
      case "home": return (0x24, true);
      case "end": return (0x23, true);
      case "page-up": return (0x21, true);
      case "page-down": return (0x22, true);
      case "insert": return (0x2D, true);
    }
    if (name.Length >= 2 && name.Length <= 3 && name[0] == 'f' && int.TryParse(name.AsSpan(1), out var f) && f is >= 1 and <= 12)
      return ((ushort)(0x70 + f - 1), false);
    if (name.Length == 1)
    {
      var c = name[0];
      if (c is >= 'a' and <= 'z') return ((ushort)char.ToUpperInvariant(c), false);
      if (c is >= '0' and <= '9') return (c, false);
    }
    return null;
  }

  private static Input MoveTo(Monitor monitor, double shareX, double shareY)
  {
    var x = Math.Clamp((int)Math.Floor(monitor.Left + Math.Clamp(shareX, 0, 1) * monitor.Width), monitor.Left, monitor.Right - 1);
    var y = Math.Clamp((int)Math.Floor(monitor.Top + Math.Clamp(shareY, 0, 1) * monitor.Height), monitor.Top, monitor.Bottom - 1);
    return MoveToPixel(x, y);
  }

  private static Input MoveToPixel(int x, int y)
  {
    int vx = GetSystemMetrics(SmXVirtualScreen), vy = GetSystemMetrics(SmYVirtualScreen);
    int vw = Math.Max(2, GetSystemMetrics(SmCxVirtualScreen)), vh = Math.Max(2, GetSystemMetrics(SmCyVirtualScreen));
    var nx = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
    var ny = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
    return Mouse(Math.Clamp(nx, 0, 65535), Math.Clamp(ny, 0, 65535), 0, MouseMove | MouseAbsolute | MouseVirtualDesk);
  }

  private static Input Mouse(int dx, int dy, uint data, uint flags) =>
    new() { Type = InputMouse, Data = new InputUnion { Mouse = new MouseInput { Dx = dx, Dy = dy, MouseData = data, Flags = flags } } };

  private static Input Keyboard(ushort vk, ushort scan, uint flags) =>
    new() { Type = InputKeyboard, Data = new InputUnion { Keyboard = new KeyboardInput { Vk = vk, Scan = scan, Flags = flags } } };

  private static string? Send(Input[] inputs)
  {
    if (inputs.Length == 0) return null;
    var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
    return sent < inputs.Length ? Refused : null;
  }

  // ---- Win32 ----

  private const uint SrcCopy = 0x00CC0020, CaptureBlt = 0x40000000;
  private const int Halftone = 4;
  private const uint BiRgb = 0, DibRgbColors = 0;
  private const uint DiNormal = 0x0003;
  private const uint CursorShowing = 0x00000001;
  private const uint MonitorInfoPrimary = 0x00000001;
  private const uint DesktopReadObjects = 0x0001;
  private const int SmCxCursor = 13, SmCyCursor = 14;
  private const int SmXVirtualScreen = 76, SmYVirtualScreen = 77, SmCxVirtualScreen = 78, SmCyVirtualScreen = 79;
  private const uint InputMouse = 0, InputKeyboard = 1;
  private const uint MouseMove = 0x0001, MouseLeftDown = 0x0002, MouseLeftUp = 0x0004, MouseRightDown = 0x0008, MouseRightUp = 0x0010;
  private const uint MouseMiddleDown = 0x0020, MouseMiddleUp = 0x0040, MouseWheel = 0x0800, MouseHWheel = 0x1000;
  private const uint MouseVirtualDesk = 0x4000, MouseAbsolute = 0x8000;
  private const uint KeyExtended = 0x0001, KeyUp = 0x0002, KeyUnicode = 0x0004;
  private const ushort VkReturn = 0x0D, VkTab = 0x09, VkShift = 0x10, VkControl = 0x11, VkMenu = 0x12;

  [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X; public int Y; }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct MonitorInfoEx
  {
    public uint Size;
    public Rect Monitor;
    public Rect Work;
    public uint Flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct CursorInfo
  {
    public uint Size;
    public uint Flags;
    public IntPtr Cursor;
    public int ScreenX;
    public int ScreenY;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct IconInfo
  {
    public int IsIcon;
    public uint HotspotX;
    public uint HotspotY;
    public IntPtr Mask;
    public IntPtr Color;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct BitmapHeader
  {
    public int Type;
    public int Width;
    public int Height;
    public int WidthBytes;
    public ushort Planes;
    public ushort BitsPixel;
    public IntPtr Bits;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct BitmapInfoHeader
  {
    public uint Size;
    public int Width;
    public int Height;
    public ushort Planes;
    public ushort BitCount;
    public uint Compression;
    public uint SizeImage;
    public int XPelsPerMeter;
    public int YPelsPerMeter;
    public uint ClrUsed;
    public uint ClrImportant;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct GuiThreadInfo
  {
    public uint Size;
    public uint Flags;
    public IntPtr Active;
    public IntPtr Focus;
    public IntPtr Capture;
    public IntPtr MenuOwner;
    public IntPtr MoveSize;
    public IntPtr Caret;
    public Rect CaretRect;
  }

  // INPUT: the union follows the type at pointer alignment (offset 8 on x64, 40 bytes in all).
  [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Data; }
  [StructLayout(LayoutKind.Explicit)] private struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyboardInput Keyboard; }
  [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int Dx; public int Dy; public uint MouseData; public uint Flags; public uint Time; public IntPtr ExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Vk; public ushort Scan; public uint Flags; public uint Time; public IntPtr ExtraInfo; }

  [UnmanagedFunctionPointer(CallingConvention.Winapi)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);

  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
  [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);
  [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
  [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr dc);
  [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorInfo(ref CursorInfo info);
  [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out NativePoint point);
  [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetIconInfo(IntPtr icon, out IconInfo info);
  [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr icon, int width, int height, uint step, IntPtr brush, uint flags);
  [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, [In] Input[] inputs, int size);
  [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
  [DllImport("wtsapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buffer, out int bytes);
  [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory);
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetUserObjectInformationW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetUserObjectInformation(IntPtr handle, int index, [Out] char[] info, int length, out int needed);
  [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
  [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfoHeader info, uint usage, out IntPtr bits, IntPtr section, uint offset);
  [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr gdiObject);
  [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(IntPtr gdiObject);
  [DllImport("gdi32.dll", EntryPoint = "GetObjectW")] private static extern int GetObject(IntPtr gdiObject, int size, out BitmapHeader bitmap);
  [DllImport("gdi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint rop);
  [DllImport("gdi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool StretchBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, int sourceWidth, int sourceHeight, uint rop);
  [DllImport("gdi32.dll")] private static extern int SetStretchBltMode(IntPtr dc, int mode);
  [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr previous);
  [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GdiFlush();
}
