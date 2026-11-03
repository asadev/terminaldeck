using System.Diagnostics;

namespace TerminalDeck.Core.Accounts;

// Claude Code renews its sign-in under a lock in its config folder: it sends the
// old renewal token (the server retires it at once) and only then saves the new
// pair. A process stopped between those two steps loses the only valid token; the
// next Claude start is refused ("invalid_grant") and Claude Code itself blanks the
// sign-in. saba-pc, 1 Nov: both Claude logins blanked this way while the app was
// restarting for updates and ending its helper Claudes the moment they answered.
// So an AI helper is never stopped while a renewal is in progress.
public static class SignInRenewal
{
  // Claude Code's lock (proper-lockfile) is touched every 5 s and treated as
  // abandoned after 60 s. A renewal is one server call plus a file save, so a
  // fresh lock normally clears within seconds; 30 s bounds every stop (the
  // update handover must finish inside its 60 s).
  public static readonly TimeSpan Abandoned = TimeSpan.FromSeconds(60);
  public static readonly TimeSpan Patience = TimeSpan.FromSeconds(30);

  // Claude Code's folder for a process: CLAUDE_CONFIG_DIR, else the user's own
  // .claude (a terminal can also start `claude` by hand). Other AIs report no
  // renewal lock and are simply given time to exit by themselves.
  public static string? ConfigFolder(string provider, IReadOnlyDictionary<string, string> environment)
  {
    if (provider != "claude") return null;
    if (Lookup(environment, "CLAUDE_CONFIG_DIR") is { } folder) return Path.IsPathFullyQualified(folder) ? folder : null;
    var home = Lookup(environment, "USERPROFILE") ?? Lookup(environment, "HOME");
    return home is not null && Path.IsPathFullyQualified(home) ? Path.Combine(home, ".claude") : null;
  }
  private static string? Lookup(IReadOnlyDictionary<string, string> environment, string name) =>
    environment.TryGetValue(name, out var value) ? value : environment.FirstOrDefault(p => p.Key.Equals(name, StringComparison.OrdinalIgnoreCase)).Value;

  // Every Claude folder this install can run: each Claude account's own folder
  // (Default = the user's .claude on the real install) plus the user's .claude.
  public static IReadOnlyList<string> ClaudeFolders(Storage.AppDataRoot root, IEnumerable<AccountProfile> accounts, string userProfile, bool stableInstall)
  {
    var folders = new List<string> { Path.Combine(userProfile, ".claude") };
    foreach (var account in accounts.Where(a => a.Provider == "claude" && a.Authentication != AccountAuthentication.ApiKey))
    {
      try { folders.Add(AccountHomes.Resolve(root, "claude", account.HomeId, userProfile, stableInstall)); }
      catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { }
    }
    return folders.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
  }

  // <config>\.oauth_refresh.lock, and the older <config>.lock beside the folder.
  public static IReadOnlyList<string> Locks(string folder)
  {
    var trimmed = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
    return [Path.Combine(trimmed, ".oauth_refresh.lock"), trimmed + ".lock"];
  }

  public static bool InProgress(string? folder, DateTimeOffset now)
  {
    if (folder is null) return false;
    foreach (var path in Locks(folder))
    {
      try
      {
        FileSystemInfo? held = Directory.Exists(path) ? new DirectoryInfo(path) : File.Exists(path) ? new FileInfo(path) : null;
        if (held is not null && now - new DateTimeOffset(held.LastWriteTimeUtc, TimeSpan.Zero) < Abandoned) return true;
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
    return false;
  }

  public static Task WaitAsync(string? folder, TimeSpan limit, TimeProvider? clock = null, CancellationToken cancellationToken = default) =>
    WaitAllAsync([folder], limit, clock, cancellationToken);

  public static async Task WaitAllAsync(IEnumerable<string?> folders, TimeSpan limit, TimeProvider? clock = null, CancellationToken cancellationToken = default)
  {
    clock ??= TimeProvider.System;
    var watched = folders.OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    var until = clock.GetUtcNow() + limit;
    while (watched.Any(f => InProgress(f, clock.GetUtcNow())) && clock.GetUtcNow() < until)
      await Task.Delay(TimeSpan.FromMilliseconds(250), clock, cancellationToken);
  }
}

// Ends a short-lived AI helper (model list, plan usage) the gentle way: let a
// renewal already under way save, close its input so it exits by itself, and kill
// its process tree only if it is still there after the grace period and no renewal
// is running.
public static class AiHelperStop
{
  public static readonly TimeSpan Grace = TimeSpan.FromSeconds(10);

  public static async Task StopAsync(Process process, string provider, IReadOnlyDictionary<string, string> environment,
    TimeSpan? grace = null, TimeSpan? patience = null, TimeProvider? clock = null)
  {
    var folder = SignInRenewal.ConfigFolder(provider, environment);
    try
    {
      if (process.HasExited) return;
      await SignInRenewal.WaitAsync(folder, patience ?? SignInRenewal.Patience, clock);
      try { process.StandardInput.Close(); } catch (Exception ex) when (ex is IOException or InvalidOperationException or ObjectDisposedException) { }
      using (var wait = new CancellationTokenSource(grace ?? Grace))
      {
        try { await process.WaitForExitAsync(wait.Token); return; }
        catch (OperationCanceledException) { }
      }
      await SignInRenewal.WaitAsync(folder, patience ?? SignInRenewal.Patience, clock);
      if (!process.HasExited) process.Kill(entireProcessTree: true);
      using var gone = new CancellationTokenSource(TimeSpan.FromSeconds(5));
      try { await process.WaitForExitAsync(gone.Token); } catch (OperationCanceledException) { }
    }
    catch (InvalidOperationException) { }
  }

  // The caller returns at once; the stop finishes in the background and owns the process.
  public static void Release(Process process, string provider, IReadOnlyDictionary<string, string> environment)
  {
    var snapshot = new Dictionary<string, string>(environment, StringComparer.OrdinalIgnoreCase);
    _ = Task.Run(async () =>
    {
      try { await StopAsync(process, provider, snapshot); }
      catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException) { }
      finally { process.Dispose(); }
    });
  }
}
