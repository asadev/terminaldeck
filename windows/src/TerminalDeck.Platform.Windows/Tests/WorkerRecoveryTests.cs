using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class WorkerRecoveryTests
{
  private static string Executable => Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new InvalidOperationException("Set TD_KEEPER_EXE.");
  private static AppDataRoot Root() => AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w3-recovery-data", Guid.NewGuid().ToString("N")));
  private static SessionRecord Row(AppDataRoot root) => new(new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "Recovery edge"), Guid.NewGuid().ToString("N"), SessionState.Starting);
  [Fact(Timeout = 45000)]
  public async Task PreparedCreateRecoversOnceAfterCrashBeforeSpawn()
  {
    var root = Root(); WindowsPrivateDirectory.Ensure(WorkerPaths.DirectoryFor(root));
    var row = Row(root); var planner = new WindowsProviderLaunchPlanner(root, @"C:\TD\tools\ai");
    var adapter = new DurableSessionProcessKeeper(root, Executable, planner, KeeperCredentials.GetOrCreate(root));
    // Durable plan was written; the supervisor died before creating the child.
    File.WriteAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".launch"), new CurrentUserDpapi(root).Protect(JsonSerializer.SerializeToUtf8Bytes(new WorkerLaunch(row, planner.Plan(row, false), new(100, 30)))));
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    try
    {
      Assert.Equal(ProcessPresence.Dead, (await adapter.ObserveAsync(row, ct.Token)).Presence);
      var first = await adapter.EnsureAsync(row, false, ct.Token); Assert.Equal(ProcessPresence.Live, first.Presence);
      var identity = File.ReadAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".identity.json"));
      var again = await adapter.EnsureAsync(row, false, ct.Token); Assert.Equal(first.LeaseIdentity, again.LeaseIdentity);
      Assert.Equal(identity, File.ReadAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".identity.json")));
    }
    finally { try { await adapter.QuitAsync(row.CreationKey, CancellationToken.None); } catch (IOException) { } }
  }
  [Fact(Timeout = 60000)]
  public async Task ExitedWorkerRetainsFinalFrameAcrossSupervisorRestartAndExplicitClose()
  {
    var root = Root(); WindowsPrivateDirectory.Ensure(WorkerPaths.DirectoryFor(root));
    var row = Row(root); var adapter = new DurableSessionProcessKeeper(root, Executable, new(root, @"C:\TD\tools\ai"), KeeperCredentials.GetOrCreate(root));
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(45)); KeeperClient? client = null;
    try
    {
      await adapter.EnsureAsync(row, false, ct.Token);
      await adapter.WriteAsync(row.CreationKey, Encoding.UTF8.GetBytes("echo W3_FINAL_FRAME\rexit\r"), ct.Token);
      WorkerSnapshot snapshot;
      do { await Task.Delay(100, ct.Token); snapshot = await adapter.SnapshotAsync(row.CreationKey, ct.Token); }
      while (!snapshot.RootExited || snapshot.ActiveProcesses != 0 || !snapshot.Replay.Contains("W3_FINAL_FRAME"));
      var ended = row with { State = SessionState.Exited, LeaseIdentity = row.CreationKey, HasStarted = true, Replay = "incomplete supervisor replay" };
      new JsonStateStore<SessionLedger>(root, "sessions").Save(new(1, 5, [ended]));
      client = await KeeperConnection.AttachAsync(root, Executable, ct.Token);
      var restored = (await client.ListAsync(ct.Token)).Sessions!.Single();
      Assert.Equal(SessionState.Exited, restored.State); Assert.Contains("W3_FINAL_FRAME", restored.Replay); Assert.DoesNotContain("incomplete supervisor replay", restored.Replay);
      await client.StopAsync(row.Definition.Id, ct.Token);
      Assert.Null((await client.ListAsync(ct.Token)).Sessions!.Single().LeaseIdentity);
    }
    finally
    {
      try { await adapter.QuitAsync(row.CreationKey, CancellationToken.None); } catch (Exception ex) when (ex is IOException or TimeoutException) { }
      var identityPath = Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json");
      if (File.Exists(identityPath))
      {
        using var identity = JsonDocument.Parse(File.ReadAllBytes(identityPath));
        using var process = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32());
        if (process.StartTime.ToUniversalTime().Ticks == identity.RootElement.GetProperty("StartedUtcTicks").GetInt64()) process.Kill();
      }
    }
  }
}
