using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Shell;

internal static partial class ShellProofNative
{
  [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
  [DllImport("user32.dll")] internal static extern nint SendMessage(nint window, uint message, nint wParam, nint lParam);
  internal static void Behind(Window window) => SetWindowPos(WinRT.Interop.WindowNative.GetWindowHandle(window), new(1), 0, 0, 0, 0, 0x13);
}
