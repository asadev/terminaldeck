using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace TerminalDeck.Hoot.Proof;

// Test-only capture. Refuses any foreground window except this proof's own
// handle and copies only that window's bounds, including its floating surface.
internal static class OwnWindowCapture
{
  [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] private struct BitmapInfo
  {
    public uint Size; public int Width, Height; public ushort Planes, Bits;
    public uint Compression, ImageSize; public int XPixels, YPixels; public uint Used, Important;
  }
  [DllImport("user32.dll")] private static extern nint SetThreadDpiAwarenessContext(nint context);
  [DllImport("user32.dll")] private static extern bool GetWindowRect(nint handle, out Rect rect);
  [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
  [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint handle);
  [DllImport("user32.dll")] private static extern nint GetDC(nint handle);
  [DllImport("user32.dll")] private static extern int ReleaseDC(nint handle, nint dc);
  [DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint dc);
  [DllImport("gdi32.dll")] private static extern nint CreateDIBSection(nint dc, ref BitmapInfo info, uint usage, out nint pixels, nint section, uint offset);
  [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint value);
  [DllImport("gdi32.dll")] private static extern bool BitBlt(nint target, int x, int y, int width, int height, nint source, int sx, int sy, uint operation);
  [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint value);
  [DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);
  public static async Task<(byte[] Pixels, int Width, int Height)> ReadAsync(Window window)
  {
    var handle = WinRT.Interop.WindowNative.GetWindowHandle(window); SetForegroundWindow(handle); await Task.Delay(200);
    var dpi = SetThreadDpiAwarenessContext(-4);
    try
    {
    if (GetForegroundWindow() != handle || !GetWindowRect(handle, out var rect)) throw new InvalidOperationException("The isolated proof window is not foreground.");
    var width = rect.Right - rect.Left; var height = rect.Bottom - rect.Top;
    if (width is < 1 or > 4096 || height is < 1 or > 4096) throw new InvalidOperationException("The proof window has unexpected bounds.");
    var source = GetDC(0); var target = CreateCompatibleDC(source); nint bitmap = 0; nint prior = 0;
    try
    {
      var info = new BitmapInfo { Size = (uint)Marshal.SizeOf<BitmapInfo>(), Width = width, Height = -height, Planes = 1, Bits = 32 };
      bitmap = CreateDIBSection(source, ref info, 0, out var pixels, 0, 0);
      if (source == 0 || target == 0 || bitmap == 0 || pixels == 0) throw new InvalidOperationException("The proof window could not be captured.");
      prior = SelectObject(target, bitmap);
      if (!BitBlt(target, 0, 0, width, height, source, rect.Left, rect.Top, 0x40CC0020) || GetForegroundWindow() != handle)
        throw new InvalidOperationException("The proof window changed during capture.");
      var buffer = new byte[checked(width * height * 4)]; Marshal.Copy(pixels, buffer, 0, buffer.Length); return (buffer, width, height);
    }
    finally
    { if (prior != 0) SelectObject(target, prior); if (bitmap != 0) DeleteObject(bitmap); if (target != 0) DeleteDC(target); if (source != 0) ReleaseDC(0, source); }
    }
    finally { if (dpi != 0) SetThreadDpiAwarenessContext(dpi); }
  }
}
