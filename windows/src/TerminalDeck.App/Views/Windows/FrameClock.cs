using System.Runtime.InteropServices;

namespace TerminalDeck.App.Shell;

// WinUI 3 paces its frames with the compositor clock on Windows 11. On Windows 10
// it waits on a timer instead, and at the default 15.6 ms timer resolution every
// 16.7 ms wait lasts two ticks: frames come about 31 ms apart, so tab switches,
// tab slides, scrolling and every transition run at 32 fps. Measured on Windows 10
// 22H2 (19045): 30.6-31.2 ms between frames by default, 16.5-17.6 ms with a 1 ms
// timer.
//
// Since Windows 10 2004 the timer resolution belongs to the process that asks for
// it (WebView2 raising its own does not help this one), so Terminal Deck raises
// it for itself, and only while one of its windows is in the foreground.
internal static class FrameClock
{
  private const uint ForegroundChanged = 0x0003, OutOfContext = 0x0000;
  private static readonly bool needed = OperatingSystem.IsWindows() && !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000);
  private static WinEventProc? callback;
  private static bool raised;

  internal static void Start()
  {
    if (!needed || callback is not null) return;
    callback = (_, _, window, _, _, _, _) => Follow(window);
    // An out-of-context hook calls back on this (UI) thread through its message loop.
    if (SetWinEventHook(ForegroundChanged, ForegroundChanged, IntPtr.Zero, callback, 0, 0, OutOfContext) == IntPtr.Zero) { callback = null; return; }
    Follow(GetForegroundWindow());
  }

  private static void Follow(IntPtr window)
  {
    _ = GetWindowThreadProcessId(window, out var process);
    var ours = window != IntPtr.Zero && process == (uint)Environment.ProcessId;
    if (ours == raised) return;
    raised = ours;
    _ = ours ? timeBeginPeriod(1) : timeEndPeriod(1);
  }

  private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
  [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc callback, uint process, uint thread, uint flags);
  [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint period);
  [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint period);
}
