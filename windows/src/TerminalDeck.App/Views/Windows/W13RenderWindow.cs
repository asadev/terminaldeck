using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Shell;

// WinUI's default maximum track size follows the current RDP desktop. Only the
// marked W13 fixture may exceed it; no display setting or other HWND is changed.
internal sealed class W13RenderWindow : IDisposable
{
  private readonly nint handle;
  private readonly Subclass callback;
  internal W13RenderWindow(Window window)
  {
    if (Environment.GetEnvironmentVariable("TD_W13_PROOF") is null) throw new InvalidOperationException("This size override is only for the marked W13 renderer.");
    handle = WinRT.Interop.WindowNative.GetWindowHandle(window); callback = Procedure;
    if (!SetWindowSubclass(handle, callback, 13, 0)) throw new IOException("Could not isolate scratch window sizing.");
  }
  private nint Procedure(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint reference)
  {
    var result = DefSubclassProc(window, message, wParam, lParam);
    if (message == 0x24 && lParam != 0)
    {
      var limits = Marshal.PtrToStructure<MinMax>(lParam);
      limits.MaxTrack = new() { X = 4096, Y = 4096 }; limits.MaxSize = limits.MaxTrack;
      Marshal.StructureToPtr(limits, lParam, false);
    }
    return result;
  }
  internal void Resize(int width, int height)
  {
    if (!GetClientRect(handle, out var client) || !GetWindowRect(handle, out var frame)) throw new IOException("Scratch window sizing could not be read.");
    var borderWidth = frame.Right - frame.Left - client.Right;
    var borderHeight = frame.Bottom - frame.Top - client.Bottom;
    if (!SetWindowPos(handle, 0, -20000, -20000, width + borderWidth, height + borderHeight, 0x34)) throw new IOException("Scratch window sizing failed.");
  }
  public void Dispose() => RemoveWindowSubclass(handle, callback, 13);
  [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] private struct MinMax { public Point Reserved, MaxSize, MaxPosition, MinTrack, MaxTrack; }
  [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
  [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate nint Subclass(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint reference);
  [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint window, Subclass procedure, nuint id, nuint reference);
  [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint window, Subclass procedure, nuint id);
  [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint window, out Rect rect);
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out Rect rect);
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}
