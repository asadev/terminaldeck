using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Shell;

internal static class WorkspaceDrag
{
  [StructLayout(LayoutKind.Sequential)] private struct Point { public int X; public int Y; }
  [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
  internal static bool Outside(Window window)
  {
    if (!GetCursorPos(out var point)) return false;
    var origin = window.AppWindow.Position; var size = window.AppWindow.Size;
    return point.X < origin.X || point.Y < origin.Y || point.X >= origin.X + size.Width || point.Y >= origin.Y + size.Height;
  }
}
