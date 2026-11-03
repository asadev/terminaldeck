using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class WorkerTests
{
  private static string Executable => Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new InvalidOperationException("Set TD_KEEPER_EXE to the scratch keeper build.");
  private static AppDataRoot Root() => AppDataRoot.Explicit(Path.Combine(@"C:\TD\out", "w3-test-data", Guid.NewGuid().ToString("N")));
  private static async Task Until(Func<Task<bool>> predicate, CancellationToken ct)
  {
    while (!await predicate()) await Task.Delay(100, ct);
  }
  [Fact(Timeout = 90000)]
  public async Task KeeperCrashAdoptsSameWorkerAndKeepsOutputBoundary()
  {
    var root = Root(); using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(75));
    KeeperClient? client = null; string? id = null;
    try
    {
      client = await KeeperConnection.AttachAsync(root, Executable, ct.Token); var first = await client.HelloAsync(ct.Token);
      id = Guid.NewGuid().ToString();
      var created = (await client.CreateAsync(new(id, "shell", root.DirectoryPath, "Crash test"), ct.Token)).Session!;
      Assert.Equal(SessionState.Running, created.State);
      await client.WriteAsync(id, Encoding.UTF8.GetBytes("echo W3_SURVIVAL_MARKER\r"), ct.Token);
      await Until(async () => (await client.ListAsync(ct.Token)).Sessions!.Single().Replay.Contains("W3_SURVIVAL_MARKER"), ct.Token);
      var identityPath = WorkerPaths.PathFor(root, created.CreationKey, ".identity.json");
      var workerBefore = File.ReadAllBytes(identityPath);
      using (var identity = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json"))))
      {
        using var supervisor = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32());
        Assert.Equal(identity.RootElement.GetProperty("StartedUtcTicks").GetInt64(), supervisor.StartTime.ToUniversalTime().Ticks);
        supervisor.Kill(); await supervisor.WaitForExitAsync(ct.Token);
      }
      client = await KeeperConnection.AttachAsync(root, Executable, ct.Token);
      var second = await client.HelloAsync(ct.Token); Assert.NotEqual(first.Instance, second.Instance);
      var adopted = (await client.ListAsync(ct.Token)).Sessions!.Single();
      Assert.Equal(created.LeaseIdentity, adopted.LeaseIdentity);
      Assert.Equal(workerBefore, File.ReadAllBytes(identityPath));
      Assert.Contains("W3_SURVIVAL_MARKER", adopted.Replay);
      await using var watch = await client.AttachAsync(id, ct.Token);
      await client.WriteAsync(id, Encoding.UTF8.GetBytes("echo W3_AFTER_RESTART\r"), ct.Token);
      var replay = new SessionReplay(); replay.Restore(watch.Snapshot);
      await foreach (var change in watch.Events(ct.Token))
      {
        Assert.True(change.Sequence > watch.Snapshot.Sequence); replay.Receive(change);
        if (replay.Text.Contains("W3_AFTER_RESTART")) break;
      }
      Assert.Contains("W3_SURVIVAL_MARKER", replay.Text);
      // Reattach again: closing a client must not relaunch or replace the worker.
      var reattached = new KeeperClient(new NamedPipeConnector(root), KeeperCredentials.GetOrCreate(root));
      await reattached.HelloAsync(ct.Token);
      Assert.Equal(created.LeaseIdentity, (await reattached.ListAsync(ct.Token)).Sessions!.Single().LeaseIdentity);
    }
    finally
    {
      if (client is not null && id is not null)
      {
        try { await client.HelloAsync(); await using var pipe = await new NamedPipeConnector(root).ConnectAsync(); await KeeperWire.WriteAsync(pipe, new KeeperRequest { Secret = Encoding.UTF8.GetString(KeeperCredentials.GetOrCreate(root)), Operation = "remove", Instance = (await client.HelloAsync()).Instance, Id = id }); await KeeperWire.ReadAsync<KeeperResponse>(pipe, true); }
        catch (IOException) { }
      }
      StopOwnSupervisor(root);
    }
  }
  [Fact(Timeout = 45000)]
  public async Task JobCountsBackgroundChildAfterRootExits()
  {
    var environment = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>().Where(e => !((string)e.Key).StartsWith('=')).ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
    await using var terminal = (ConPtyProcess)await new ConPtyTerminalFactory().StartAsync(new(Path.Combine(Environment.SystemDirectory, "cmd.exe"), ["/d", "/q"], environment, @"C:\TD"), new(100, 30));
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    var drain = Task.Run(async () => { try { await foreach (var _ in terminal.ReadOutputAsync(ct.Token)) { } } catch (Exception ex) when (ex is OperationCanceledException or IOException) { } });
    await terminal.WriteAsync(Encoding.UTF8.GetBytes("start \"\" /b cmd.exe /d /c ping.exe -n 25 127.0.0.1\r"), ct.Token);
    await Until(() => Task.FromResult(terminal.ActiveProcessCount > 1), ct.Token);
    await terminal.WriteAsync(Encoding.UTF8.GetBytes("exit\r"), ct.Token);
    await terminal.WaitForExitAsync(ct.Token);
    Assert.True(terminal.RootExited); Assert.True(terminal.ActiveProcessCount > 0);
    var observation = new ProcessObservation(ProcessPresence.Live, "owned", false, terminal.ActiveProcessCount);
    Assert.False(observation.Idle);
    await terminal.QuitAsync(ct.Token); await drain;
  }
  [Fact(Timeout = 45000)]
  public async Task PrivatePipeRejectsBadSecretAndOldInstance()
  {
    var root = Root(); using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    try
    {
      var client = await KeeperConnection.AttachAsync(root, Executable, ct.Token); await client.HelloAsync(ct.Token);
      await using (var pipe = await new NamedPipeConnector(root).ConnectAsync(ct.Token))
      {
        await KeeperWire.WriteAsync(pipe, new KeeperRequest { Secret = new string('x', 64), Operation = "hello" }, cancellationToken: ct.Token);
        await Assert.ThrowsAnyAsync<IOException>(async () => await KeeperWire.ReadAsync<KeeperResponse>(pipe, true, ct.Token));
      }
      await using (var pipe = await new NamedPipeConnector(root).ConnectAsync(ct.Token))
      {
        await KeeperWire.WriteAsync(pipe, new KeeperRequest { Secret = Encoding.UTF8.GetString(KeeperCredentials.GetOrCreate(root)), Operation = "create", Instance = Guid.NewGuid(), Launch = new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "Must not start") }, cancellationToken: ct.Token);
        await Assert.ThrowsAnyAsync<IOException>(async () => await KeeperWire.ReadAsync<KeeperResponse>(pipe, true, ct.Token));
      }
      Assert.Empty((await client.ListAsync(ct.Token)).Sessions!);
    }
    finally { StopOwnSupervisor(root); }
  }
  private static void StopOwnSupervisor(AppDataRoot root)
  {
    var path = Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json"); if (!File.Exists(path)) return;
    try
    {
      using var identity = JsonDocument.Parse(File.ReadAllBytes(path));
      using var process = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32());
      if (process.StartTime.ToUniversalTime().Ticks == identity.RootElement.GetProperty("StartedUtcTicks").GetInt64()) process.Kill();
    }
    catch (ArgumentException) { }
  }
}
