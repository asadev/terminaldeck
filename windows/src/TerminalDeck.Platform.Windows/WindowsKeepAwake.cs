using System.Runtime.InteropServices;

namespace TerminalDeck.Platform.Windows;

// Execution-state requests belong to their OS thread. The caller owns the UI
// thread, sets/clears here on that thread, and clears again when its window closes.
public sealed class WindowsKeepAwake : IDisposable
{
  private readonly uint owner = GetCurrentThreadId();
  public void Set(bool enabled)
  {
    if (GetCurrentThreadId() != owner) throw new InvalidOperationException("Keep awake must change on the owning window thread.");
    if (SetThreadExecutionState(0x80000000u | (enabled ? 0x00000001u : 0)) == 0) throw new IOException("Windows could not change its sleep request.");
  }
  public void Dispose() => Set(false);
  [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll", SetLastError = true)] private static extern uint SetThreadExecutionState(uint flags);
}
