namespace TerminalDeck.Platform.Windows;

/// The two-second guard of the Cloud trust presses (plan: "the 2-second guard on Windows' own remote input"). This app
/// moves this PC's mouse and keyboard only for a phone that controls it (`WindowsScreenHost`, SendInput); for two
/// seconds after that, a press on a Cloud trust button cannot be taken as the person's own and is refused.
public static class WindowsRemoteInputGuard
{
  private static long lastInput;
  public static readonly TimeSpan Window = TimeSpan.FromSeconds(2);
  public static void Touch() => Volatile.Write(ref lastInput, Environment.TickCount64);
  public static bool JustNow
  {
    get
    {
      var last = Volatile.Read(ref lastInput);
      return last != 0 && Environment.TickCount64 - last < (long)Window.TotalMilliseconds;
    }
  }
}
