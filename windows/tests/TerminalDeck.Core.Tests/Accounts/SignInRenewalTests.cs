using System.Diagnostics;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.Core.Tests.Accounts;

// saba-pc, 1 Nov: both Claude logins were blanked by Claude Code after the app ended
// helper Claudes mid-renewal. These pin the guard that prevents it.
public sealed class SignInRenewalTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-renewal-" + Guid.NewGuid().ToString("N"), ".claude");
  public SignInRenewalTests() => Directory.CreateDirectory(folder);
  public void Dispose()
  {
    var parent = Path.GetDirectoryName(folder)!;
    for (var attempt = 0; attempt < 20; attempt++)
    {
      try { if (Directory.Exists(parent)) Directory.Delete(parent, true); return; }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Thread.Sleep(250); }
    }
  }

  [Fact]
  public void ARenewalCountsOnlyWhileClaudesLockIsFresh()
  {
    var now = DateTimeOffset.UtcNow;
    Assert.False(SignInRenewal.InProgress(folder, now));
    var current = Directory.CreateDirectory(Path.Combine(folder, ".oauth_refresh.lock"));
    Assert.True(SignInRenewal.InProgress(folder, DateTimeOffset.UtcNow));
    // Claude Code treats a lock untouched for 60 s as abandoned; so does the app.
    current.LastWriteTimeUtc = DateTime.UtcNow.AddSeconds(-61);
    Assert.False(SignInRenewal.InProgress(folder, DateTimeOffset.UtcNow));
    current.Delete();
    // The older lock sits beside the folder (<config>.lock).
    Directory.CreateDirectory(folder + ".lock");
    Assert.True(SignInRenewal.InProgress(folder + Path.DirectorySeparatorChar, DateTimeOffset.UtcNow));
    Assert.False(SignInRenewal.InProgress(null, DateTimeOffset.UtcNow));
  }

  [Fact]
  public void OnlyClaudesOwnConfigFolderIsWatched()
  {
    var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["CLAUDE_CONFIG_DIR"] = folder, ["CODEX_HOME"] = folder };
    Assert.Equal(folder, SignInRenewal.ConfigFolder("claude", environment));
    Assert.Null(SignInRenewal.ConfigFolder("codex", environment));
    Assert.Null(SignInRenewal.ConfigFolder("claude", new Dictionary<string, string> { ["CLAUDE_CONFIG_DIR"] = "relative" }));
    // A terminal without CLAUDE_CONFIG_DIR may run `claude` by hand: the user's own .claude.
    var profile = Path.GetDirectoryName(folder)!;
    Assert.Equal(Path.Combine(profile, ".claude"), SignInRenewal.ConfigFolder("claude", new Dictionary<string, string> { ["UserProfile"] = profile }));
  }

  [Fact]
  public void EveryClaudeFolderOfTheInstallIsWatchedForTheUpdate()
  {
    var profile = Path.GetDirectoryName(folder)!;
    var root = TerminalDeck.Core.Storage.AppDataRoot.Explicit(Path.Combine(profile, "AppData", "Local", "TerminalDeckStable"));
    var own = Guid.NewGuid().ToString("N");
    AccountProfile Row(string provider, string home, AccountAuthentication kind = AccountAuthentication.Subscription) => new(Guid.NewGuid().ToString("N"), provider, "x", null, kind, false, home);
    var accounts = new[] { Row("claude", AccountHomes.ExistingLogin), Row("claude", own), Row("codex", Guid.NewGuid().ToString("N")), Row("claude", Guid.NewGuid().ToString("N"), AccountAuthentication.ApiKey) };
    var stable = SignInRenewal.ClaudeFolders(root, accounts, profile, stableInstall: true);
    Assert.Equal([Path.Combine(profile, ".claude"), Path.Combine(root.DirectoryPath, "accounts", own, "claude")], stable);
    // A test copy never resolves the real login; its own folders are still watched.
    var test = SignInRenewal.ClaudeFolders(TerminalDeck.Core.Storage.AppDataRoot.Explicit(Path.Combine(profile, "scratch")), accounts, profile, stableInstall: false);
    Assert.Equal(2, test.Count);
  }

  [Fact]
  public async Task WaitingForSeveralFoldersHoldsWhileAnyOfThemRenews()
  {
    var other = Path.Combine(Path.GetDirectoryName(folder)!, "other"); Directory.CreateDirectory(other);
    var held = Directory.CreateDirectory(Path.Combine(other, ".oauth_refresh.lock"));
    var waiting = SignInRenewal.WaitAllAsync([folder, null, other], TimeSpan.FromSeconds(30));
    await Task.Delay(TimeSpan.FromSeconds(1));
    Assert.False(waiting.IsCompleted);
    held.Delete();
    await waiting.WaitAsync(TimeSpan.FromSeconds(5));
  }

  [Fact]
  public async Task AHelperThatEndsAtEndOfInputExitsByItselfAndIsNotKilled()
  {
    using var process = Start(endsAtEndOfInput: true);
    await AiHelperStop.StopAsync(process, "claude", Environment(), grace: TimeSpan.FromSeconds(10), patience: TimeSpan.FromSeconds(5));
    Assert.True(process.HasExited);
    Assert.Equal(0, process.ExitCode);
  }

  [Fact]
  public async Task AHelperIsNeverEndedWhileItsSignInRenewalIsHeld()
  {
    var held = Directory.CreateDirectory(Path.Combine(folder, ".oauth_refresh.lock"));
    using var process = Start(endsAtEndOfInput: false);
    var stopping = AiHelperStop.StopAsync(process, "claude", Environment(), grace: TimeSpan.FromMilliseconds(200), patience: TimeSpan.FromSeconds(30));
    await Task.Delay(TimeSpan.FromSeconds(1.5));
    Assert.False(process.HasExited);
    Assert.False(stopping.IsCompleted);
    held.Delete();
    await stopping.WaitAsync(TimeSpan.FromSeconds(15));
    // It ignores end of input, so after the renewal it is ended as a last resort.
    Assert.True(process.HasExited);
  }

  [Fact]
  public async Task AStuckRenewalLockOnlyDelaysTheStopUpToItsPatience()
  {
    var held = Directory.CreateDirectory(Path.Combine(folder, ".oauth_refresh.lock"));
    using var process = Start(endsAtEndOfInput: false);
    var clock = Stopwatch.StartNew();
    await AiHelperStop.StopAsync(process, "claude", Environment(), grace: TimeSpan.FromMilliseconds(200), patience: TimeSpan.FromSeconds(1)).WaitAsync(TimeSpan.FromSeconds(15));
    Assert.True(process.HasExited);
    Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10));
    held.Delete();
  }

  private Dictionary<string, string> Environment() => new(StringComparer.OrdinalIgnoreCase) { ["CLAUDE_CONFIG_DIR"] = folder };
  private static Process Start(bool endsAtEndOfInput)
  {
    ProcessStartInfo start;
    if (OperatingSystem.IsWindows())
    {
      start = new(Path.Combine(System.Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"));
      foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command", endsAtEndOfInput ? "$null = [Console]::In.ReadToEnd()" : "Start-Sleep -Seconds 60" }) start.ArgumentList.Add(argument);
    }
    else
    {
      start = new(endsAtEndOfInput ? "/bin/cat" : "/bin/sleep");
      if (!endsAtEndOfInput) start.ArgumentList.Add("60");
    }
    start.UseShellExecute = false; start.CreateNoWindow = true;
    start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
    return Process.Start(start) ?? throw new IOException("The test helper could not start.");
  }
}

// "Restart to update" (WindowsUpdateStatus): Windows' forced package shutdown ends
// every app process, so the package is replaced only after renewals have saved.
public sealed class PackageUpdateSequenceTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-update-" + Guid.NewGuid().ToString("N"), ".claude");
  public PackageUpdateSequenceTests() => Directory.CreateDirectory(folder);
  public void Dispose() { try { Directory.Delete(Path.GetDirectoryName(folder)!, true); } catch (IOException) { } }

  [Fact]
  public async Task ThePackageIsReplacedOnlyAfterTheHandoverAndAfterARenewalHasSaved()
  {
    var held = Directory.CreateDirectory(Path.Combine(folder, ".oauth_refresh.lock"));
    var steps = new System.Collections.Concurrent.ConcurrentQueue<string>();
    var applied = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var update = TerminalDeck.Core.Platform.PackageUpdateSequence.RunAsync(
      () => { steps.Enqueue("handover"); return Task.CompletedTask; },
      () => { steps.Enqueue("settle"); return SignInRenewal.WaitAllAsync([folder], SignInRenewal.Patience); },
      () => { steps.Enqueue("apply"); applied.TrySetResult(); return Task.CompletedTask; },
      () => { steps.Enqueue("resume"); return Task.CompletedTask; });
    await Task.Delay(TimeSpan.FromSeconds(1.5));
    Assert.False(applied.Task.IsCompleted);
    Assert.Equal(["handover", "settle"], steps);
    held.Delete();
    await update.WaitAsync(TimeSpan.FromSeconds(5));
    // Still running after Windows' call: nothing newer, sessions come back.
    Assert.Equal(["handover", "settle", "apply", "resume"], steps);
  }

  [Fact]
  public async Task AFailedReplacementBringsTheSessionsBackAndAFailedHandoverChangesNothing()
  {
    var steps = new List<string>();
    await Assert.ThrowsAsync<IOException>(() => TerminalDeck.Core.Platform.PackageUpdateSequence.RunAsync(
      () => { steps.Add("handover"); return Task.CompletedTask; }, () => { steps.Add("settle"); return Task.CompletedTask; },
      () => throw new IOException("refused"), () => { steps.Add("resume"); return Task.CompletedTask; }));
    Assert.Equal(["handover", "settle", "resume"], steps);
    steps.Clear();
    await Assert.ThrowsAsync<IOException>(() => TerminalDeck.Core.Platform.PackageUpdateSequence.RunAsync(
      () => throw new IOException("busy"), () => { steps.Add("settle"); return Task.CompletedTask; },
      () => { steps.Add("apply"); return Task.CompletedTask; }, () => { steps.Add("resume"); return Task.CompletedTask; }));
    Assert.Empty(steps);
  }
}
