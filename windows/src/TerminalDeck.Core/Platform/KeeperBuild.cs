namespace TerminalDeck.Core.Platform;

// Whether the session keeper that runs now is an OLDER build's than this app's (Windows: each package version carries its
// own keeper under keeper\<17-digit build stamp>\TerminalDeck.Keeper.exe, the stamp being its UTC build time). Only an
// older keeper hands its sessions over to this build; a newer one (an older app copy sharing the data root: a loose
// review layout, a rollback) is left alone (review #27 item 6). Unknown is "no": a keeper is never moved on a guess.
public static class KeeperBuild
{
  public static bool IsOlder(string? runningProgram, string ownProgram) =>
    Stamp(runningProgram) is { } running && Stamp(ownProgram) is { } own && string.CompareOrdinal(running, own) < 0;

  /// The keeper's build stamp: the 17 digits of the folder that holds it, or null.
  public static string? Stamp(string? program)
  {
    if (string.IsNullOrWhiteSpace(program)) return null;
    var folder = Path.GetFileName(Path.GetDirectoryName(program.Replace('\\', '/').TrimEnd('/')) ?? "");
    return folder.Length == 17 && folder.All(char.IsAsciiDigit) ? folder : null;
  }
}

// The keeper's hand-over for an update or a move to a newer build: the keeper saves its sessions and exits (`prepare`),
// then the app waits for it to be gone (`gone`). While it runs no new keeper may be started from the old package. Any
// failure ends that state at once (review #27 item 4: a slow exit left it stuck, so the app refused every keeper
// connection until it was restarted); success keeps it until the caller resumes (Done).
public sealed class KeeperHandover
{
  private volatile bool active;
  public bool Active => active;

  public async Task RunAsync(Func<Task> prepare, Func<Task> gone)
  {
    active = true;
    try { await prepare().ConfigureAwait(false); await gone().ConfigureAwait(false); }
    catch { active = false; throw; }
  }

  public void Done() => active = false;
}
