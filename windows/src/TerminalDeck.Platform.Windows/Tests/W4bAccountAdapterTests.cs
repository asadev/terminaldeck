using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class W4bAccountAdapterTests
{
  [Fact(Timeout = 90000)]
  public async Task LiveDurableTerminalSwitchKeepsIdentityAndLatestTranscriptAcrossKeeperRecovery()
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w4b-account-data", Guid.NewGuid().ToString("N"))); WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    var executable = Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new InvalidOperationException("Set TD_KEEPER_EXE.");
    var real = new DurableSessionProcessKeeper(root, executable, new(root, @"C:\TD\tools\ai"), KeeperCredentials.GetOrCreate(root));
    var adapter = new ShellFixtureProcesses(real); var store = new JsonStateStore<SessionLedger>(root, "sessions"); var keeper = new SessionKeeper(store, adapter, new ConversationFiles(root));
    var definition = new SessionDefinition(Guid.NewGuid().ToString(), "codex", root.DirectoryPath, "W4b fixture conversation", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString());
    var source = Path.Combine(root.DirectoryPath, "accounts", definition.AccountHome!, "codex", "sessions", "2026", "10", "29", "rollout-" + definition.ConversationId + ".jsonl"); Directory.CreateDirectory(Path.GetDirectoryName(source)!);
    File.WriteAllText(source, JsonSerializer.Serialize(new { type = "session_meta", payload = new { id = definition.ConversationId, cwd = definition.Cwd } }) + "\n");
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(75));
    try
    {
      var original = await keeper.CreateAsync(definition, ct.Token);
      await keeper.WriteAsync(definition.Id, keeper.Instance, Encoding.UTF8.GetBytes("Write-Output 'W4B_BEFORE_SWITCH'\r"), ct.Token);
      WorkerSnapshot before;
      do { await Task.Delay(100, ct.Token); before = await real.SnapshotAsync(original.CreationKey, ct.Token); } while (before.Replay.Split("W4B_BEFORE_SWITCH").Length < 3);
      await keeper.RestoreWorkerReplayAsync(definition.Id, original.CreationKey, before.Replay, false, null, ct.Token);
      var destination = definition with { AccountId = Guid.NewGuid().ToString("N"), AccountHome = Guid.NewGuid().ToString("N") };
      adapter.AfterQuit = () => File.AppendAllText(source, "{\"type\":\"event_msg\",\"payload\":{\"message\":\"last fixture turn\"}}\n");
      var switched = await keeper.SwitchAccountAsync(destination, 0, Guid.NewGuid().ToString("N"), ct.Token);
      Assert.Equal(definition.Id, switched.Definition.Id); Assert.Equal(definition.ConversationId, switched.Definition.ConversationId); Assert.Contains("W4B_BEFORE_SWITCH", switched.Replay);
      var copied = Path.Combine(root.DirectoryPath, "accounts", destination.AccountHome!, "codex", "sessions", "2026", "10", "29", Path.GetFileName(source));
      Assert.Equal(File.ReadAllBytes(source), File.ReadAllBytes(copied)); Assert.Contains("last fixture turn", File.ReadAllText(copied));
      var restarted = new SessionKeeper(store, adapter, new ConversationFiles(root)); await restarted.RecoverAsync(ct.Token);
      Assert.Equal(switched.CreationKey, restarted.Get(definition.Id).CreationKey); Assert.Equal(destination.AccountId, restarted.Get(definition.Id).Definition.AccountId);
      await restarted.WriteAsync(definition.Id, restarted.Instance, Encoding.UTF8.GetBytes("Write-Output 'W4B_AFTER_SWITCH'\r"), ct.Token);
      WorkerSnapshot after;
      do { await Task.Delay(100, ct.Token); after = await real.SnapshotAsync(switched.CreationKey, ct.Token); } while (after.Replay.Split("W4B_AFTER_SWITCH").Length < 3);
      Assert.True(adapter.Resumed); await restarted.StopAsync(definition.Id, restarted.Instance, ct.Token);
    }
    finally
    {
      foreach (var path in Directory.EnumerateFiles(WorkerPaths.DirectoryFor(root), "*.identity.json"))
      {
        var identity = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(path))!;
        try { using var process = Process.GetProcessById(identity.Pid); if (process.StartTime.ToUniversalTime().Ticks == identity.StartedUtcTicks && process.ProcessName == "TerminalDeck.Keeper") { process.Kill(); await process.WaitForExitAsync(); } } catch (ArgumentException) { }
      }
      await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2");
      Assert.Null(await new WindowsCredentialStore(root).ReadAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2"));
      Directory.Delete(root.DirectoryPath, true);
    }
  }
  [Trait("Group", "RealPc")] [Fact]
  public void ExactResumeAndBriefAreArgumentsRatherThanTypedTerminalCommands()
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w4b-launch-data", Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(root.DirectoryPath);
    try
    {
      var id = Guid.NewGuid().ToString("N"); var conversation = Guid.NewGuid().ToString(); var planner = new WindowsProviderLaunchPlanner(root, @"C:\TD\tools\ai");
      var definition = new SessionDefinition(Guid.NewGuid().ToString(), "codex", root.DirectoryPath, "Fixture", id, id, conversation, InitialPrompt: "brief with spaces and $(never execute)");
      var resumed = planner.Plan(new(definition, "fixture", SessionState.Starting), true);
      Assert.Contains("resume", resumed.Arguments); Assert.Contains(conversation, resumed.Arguments); Assert.DoesNotContain(definition.InitialPrompt, resumed.Arguments);
      var fresh = planner.Plan(new(definition with { ConversationId = null }, "fixture", SessionState.Starting), false); Assert.Equal(definition.InitialPrompt, fresh.Arguments.Last());
      Assert.Equal(Path.Combine(root.DirectoryPath, "accounts", id, "codex"), fresh.Environment["CODEX_HOME"]);
    }
    finally { Directory.Delete(root.DirectoryPath, true); }
  }
  private sealed class ShellFixtureProcesses(DurableSessionProcessKeeper real) : ISessionProcessKeeper
  {
    public bool Resumed; public Action? AfterQuit;
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => real.ObserveAsync(row, ct);
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct)
    { Resumed |= resume; return real.EnsureAsync(row with { Definition = row.Definition with { Provider = "shell", InitialPrompt = null } }, false, ct); }
    public async ValueTask QuitAsync(string lease, CancellationToken ct) { await real.QuitAsync(lease, ct); AfterQuit?.Invoke(); }
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => real.WriteAsync(lease, bytes, ct);
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => real.ResizeAsync(lease, size, ct);
  }
}
