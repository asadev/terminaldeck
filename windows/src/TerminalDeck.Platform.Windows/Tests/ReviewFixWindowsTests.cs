using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Windows.Tests;

public sealed class ReviewFixWindowsTests
{
  private static string KeeperExe => Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new InvalidOperationException("Choose the test keeper.");
  private static AppDataRoot Scratch() => AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-review-fix-" + Guid.NewGuid().ToString("N")));
  private static async Task Until(Func<Task<bool>> predicate, CancellationToken ct)
  { while (!await predicate()) await Task.Delay(100, ct); }
  private static Process OwnedWorker(AppDataRoot root, SessionRecord row)
  {
    var identity = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".identity.json")))!;
    var process = Process.GetProcessById(identity.Pid);
    if (process.StartTime.ToUniversalTime().Ticks != identity.StartedUtcTicks || identity.SessionId != row.Definition.Id) { process.Dispose(); throw new IOException("The test worker identity changed."); }
    return process;
  }
  private static async Task StopOwnedSupervisorAsync(AppDataRoot root)
  {
    var path = Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json");
    if (!File.Exists(path)) return;
    using var identity = JsonDocument.Parse(File.ReadAllText(path));
    Process current;
    try { current = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32()); }
    catch (ArgumentException) { return; }
    using (current)
    {
      // Pin this process handle before validating identity, so a reused PID can
      // never turn test cleanup into a stop of another keeper.
      _ = current.Handle;
      if (current.StartTime.ToUniversalTime().Ticks != identity.RootElement.GetProperty("StartedUtcTicks").GetInt64() ||
          !string.Equals(current.MainModule?.FileName, Path.GetFullPath(KeeperExe), StringComparison.OrdinalIgnoreCase))
        throw new IOException("The scratch supervisor identity changed; it was left running.");
      if (!current.HasExited) current.Kill();
      using var stopped = new CancellationTokenSource(TimeSpan.FromSeconds(10));
      await current.WaitForExitAsync(stopped.Token);
    }
  }
  private static async Task WaitForKeeperLocksAsync(AppDataRoot root)
  {
    using var released = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    foreach (var relative in new[] { Path.Combine("keeper", "supervisor.lock"), Path.Combine("keeper", "chat-workers", "service.lock"), Path.Combine("state", "hoot-service.lock") })
    {
      var path = Path.Combine(root.DirectoryPath, relative);
      while (File.Exists(path))
      {
        try { using var ownership = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None); break; }
        catch (IOException) { await Task.Delay(100, released.Token); }
      }
    }
  }

  [Fact(Timeout = 90000)] public async Task M8AbruptWorkerKillContainsConsoleIndependentChildBeforeRecovery()
  {
    var root = Scratch(); WindowsPrivateDirectory.Ensure(root.DirectoryPath); using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75));
    var row = new SessionRecord(new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "Owned crash fixture"), Guid.NewGuid().ToString("N"), SessionState.Starting);
    var planner = new WindowsProviderLaunchPlanner(root, "unused-tools"); var adapter = new DurableSessionProcessKeeper(root, KeeperExe, planner, KeeperCredentials.GetOrCreate(root));
    var sleeper = Path.Combine(root.DirectoryPath, "sleeper.ps1"); File.WriteAllText(sleeper, "while ($true) { Start-Sleep -Milliseconds 250 }\n");
    var fixture = Path.Combine(root.DirectoryPath, "parent.ps1");
    File.WriteAllText(fixture, """
      param([string]$Root)
      $start = New-Object Diagnostics.ProcessStartInfo
      $start.FileName = Join-Path $PSHOME 'powershell.exe'
      $start.Arguments = '-NoProfile -NonInteractive -File "' + (Join-Path $Root 'sleeper.ps1') + '"'
      $start.UseShellExecute = $false
      $start.CreateNoWindow = $true
      $child = [Diagnostics.Process]::Start($start)
      @{Pid=$child.Id; StartedUtcTicks=$child.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content (Join-Path $Root 'child.json.tmp')
      Move-Item (Join-Path $Root 'child.json.tmp') (Join-Path $Root 'child.json')
      while ($true) { Start-Sleep -Milliseconds 250 }
      """);
    var plan = planner.Plan(row, false) with { Arguments = ["-NoProfile", "-NonInteractive", "-File", fixture, root.DirectoryPath] };
    WindowsPrivateDirectory.Ensure(WorkerPaths.DirectoryFor(root));
    File.WriteAllBytes(WorkerPaths.PathFor(root, row.CreationKey, ".launch"), new CurrentUserDpapi(root).Protect(JsonSerializer.SerializeToUtf8Bytes(new WorkerLaunch(row, plan, new(100, 30)))));
    Process? child = null;
    try
    {
      DetachedProcess.Start(KeeperExe, ["--user-data-dir", root.DirectoryPath, "--worker", row.CreationKey], Path.GetDirectoryName(KeeperExe)!);
      await Until(async () => (await adapter.ObserveAsync(row, timeout.Token)).Presence == ProcessPresence.Live, timeout.Token);
      await Until(() => Task.FromResult(File.Exists(Path.Combine(root.DirectoryPath, "child.json"))), timeout.Token);
      using var data = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.DirectoryPath, "child.json")));
      child = Process.GetProcessById(data.RootElement.GetProperty("Pid").GetInt32());
      Assert.Equal(data.RootElement.GetProperty("StartedUtcTicks").GetInt64(), child.StartTime.ToUniversalTime().Ticks);
      var snapshot = await adapter.SnapshotAsync(row.CreationKey, timeout.Token); Assert.True(snapshot.ActiveProcesses >= 2); Assert.False(child.HasExited);
      using var worker = OwnedWorker(root, row); worker.Kill(); await worker.WaitForExitAsync(timeout.Token); await child.WaitForExitAsync(timeout.Token);
      Assert.True(child.HasExited);
      Assert.Equal(ProcessPresence.Dead, (await adapter.ObserveAsync(row with { HasStarted = true }, timeout.Token)).Presence);
      // Dead-shell recovery cannot create a replacement or a second child.
      var state = new JsonStateStore<SessionLedger>(root, "sessions"); state.Save(new(1, 1, [row with { State = SessionState.Running, HasStarted = true, LeaseIdentity = row.CreationKey }]));
      var core = new SessionKeeper(state, adapter); await core.RecoverAsync(timeout.Token);
      Assert.Equal(SessionState.Exited, core.Get(row.Definition.Id).State); Assert.Null(core.Get(row.Definition.Id).LeaseIdentity);
      Assert.Single(Directory.GetFiles(WorkerPaths.DirectoryFor(root), "*.identity.json"));
    }
    finally
    {
      if (child is not null) { if (!child.HasExited) child.Kill(); child.Dispose(); }
      try { using var worker = OwnedWorker(root, row); if (!worker.HasExited) { worker.Kill(); await worker.WaitForExitAsync(); } } catch (ArgumentException) { }
      await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2");
      Directory.Delete(root.DirectoryPath, true);
    }
  }

  [Fact(Timeout = 90000)] public async Task M8KeeperKillKeepsTheSameWorkerAliveAndExplicitQuitEndsItsTree()
  {
    var root = Scratch(); WindowsPrivateDirectory.Ensure(root.DirectoryPath); using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75));
    SessionRecord? row = null; Process? supervisor = null;
    var adapter = new DurableSessionProcessKeeper(root, KeeperExe, new(root, "unused-tools"), KeeperCredentials.GetOrCreate(root));
    try
    {
      var keeper = await KeeperConnection.AttachAsync(root, KeeperExe, timeout.Token);
      row = (await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "Keeper crash fixture"), timeout.Token)).Session!;
      using var worker = OwnedWorker(root, row);
      var path = Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json"); using var identity = JsonDocument.Parse(File.ReadAllText(path));
      supervisor = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32()); Assert.Equal(identity.RootElement.GetProperty("StartedUtcTicks").GetInt64(), supervisor.StartTime.ToUniversalTime().Ticks);
      supervisor.Kill(); await supervisor.WaitForExitAsync(timeout.Token); supervisor.Dispose(); supervisor = null;
      Assert.False(worker.HasExited); Assert.Equal(ProcessPresence.Live, (await adapter.ObserveAsync(row, timeout.Token)).Presence);
      var restored = await KeeperConnection.AttachAsync(root, KeeperExe, timeout.Token);
      using var after = OwnedWorker(root, row); Assert.Equal(worker.Id, after.Id); Assert.Equal(worker.StartTime, after.StartTime);
      await restored.StopAsync(row.Definition.Id, timeout.Token); await worker.WaitForExitAsync(timeout.Token);
      Assert.True(worker.HasExited);
    }
    finally
    {
      if (row is not null) try { await adapter.QuitAsync(row.CreationKey, CancellationToken.None); } catch (Exception e) when (e is IOException or TimeoutException) { }
      await StopOwnedSupervisorAsync(root);
      // Wait for the supervisor's service handles as well as its exit signal
      // before deleting the owned fixture. Never ignore a retained service lock.
      await WaitForKeeperLocksAsync(root);
      supervisor?.Dispose(); await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2"); Directory.Delete(root.DirectoryPath, true);
    }
  }

  [Fact] public void M5TerminalAndChatUseTheSameOrdinaryNpmResolverAndKeepIsolatedHomes()
  {
    var root = Scratch(); WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    try
    {
      var tools = Path.Combine(root.DirectoryPath, "ordinary-npm");
      var native = Path.Combine(tools, "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe");
      Directory.CreateDirectory(Path.GetDirectoryName(native)!); File.WriteAllText(native, "never executed");
      var chat = new ChatRecord(1, new(Guid.NewGuid().ToString(), "codex", root.DirectoryPath, "Fixture", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), Guid.NewGuid().ToString("N"), [], []);
      var terminal = new WindowsProviderLaunchPlanner(root, tools).Plan(ChatSessions.Session(chat), false);
      var conversation = new WindowsChatLaunchPlanner(root, tools).Plan(chat);
      Assert.Equal(native, terminal.Executable); Assert.Equal(terminal.Executable, conversation.Executable);
      Assert.Equal(terminal.Environment["CODEX_HOME"], conversation.Environment["CODEX_HOME"]); Assert.StartsWith(root.DirectoryPath, conversation.Environment["CODEX_HOME"]);
      Assert.Contains("cli_auth_credentials_store=\"file\"", conversation.Arguments);
    }
    finally { Directory.Delete(root.DirectoryPath, true); }
  }

  [Fact(Timeout = 90000)] public async Task M2ReaderFailureReconnectAndM4EndUseTheActualWorkerAndServicePipe()
  {
    var root = Scratch(); WindowsPrivateDirectory.Ensure(root.DirectoryPath); using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75));
    var tools = Path.Combine(root.DirectoryPath, "tools"); var entry = Path.Combine(tools, "node_modules", "@anthropic-ai", "claude-code", "cli.js"); Directory.CreateDirectory(Path.GetDirectoryName(entry)!);
    File.WriteAllText(entry, """
      const rl=require('readline').createInterface({input:process.stdin});
      const emit=r=>process.stdout.write(JSON.stringify(r)+'\n');
      emit({type:'system',subtype:'init',session_id:'review-exact'});
      rl.on('line',line=>{
        const row=JSON.parse(line);if(row.type!=='user')return;
        if(row.message.content[0].text==='fail') { process.stdout.write('{malformed\n');return; }
        emit({type:'assistant',message:{id:row.uuid,content:[{type:'text',text:process.argv.includes('--resume')?'exact conversation resumed':'not resumed'}]}});
        emit({type:'result',subtype:'success'});
      });
      """);
    var accounts = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [new SyntheticAccount()]); var account = await accounts.CreateAsync("claude", "Synthetic");
    var processes = new WindowsChatProcessKeeper(root, KeeperExe, tools, KeeperCredentials.GetOrCreate(root));
    var core = new ChatSessions(new ChatHistory(root), processes, accounts);
    using var serving = new CancellationTokenSource(); var server = new ChatSessionsPipeServer(root, core, KeeperCredentials.GetOrCreate(root)).RunAsync(serving.Token);
    ChatRecord? chat = null;
    try
    {
      var client = await WindowsChatSessionsClient.ConnectAsync(root, KeeperCredentials.GetOrCreate(root), timeout.Token);
      chat = await client.CreateAsync("claude", root.DirectoryPath, account.Id, cancellationToken: timeout.Token);
      var first = Guid.NewGuid().ToString(); await client.SendAsync(chat.Definition.Id, first, "fail", cancellationToken: timeout.Token);
      await Until(() => Task.FromResult(core.Get(chat.Definition.Id).Events.Any(e => e.Kind == "connectionLost")), timeout.Token);
      Assert.Equal(ChatMessageState.Uncertain, core.Get(chat.Definition.Id).Messages.Single().State); Assert.False(core.Get(chat.Definition.Id).Busy);
      // Direct worker retry returns its saved uncertainty and cannot replay stdin.
      var state = core.Get(chat.Definition.Id); var receipt = await processes.SendAsync(state, state.Messages.Single(), timeout.Token); Assert.Equal(ChatMessageState.Uncertain, receipt.State);
      await client.ContinueWithoutResendingAsync(chat.Definition.Id, timeout.Token);
      Assert.Equal(ChatMessageState.Uncertain, client.Get(chat.Definition.Id).Messages.Single().State);
      Assert.Contains(client.Get(chat.Definition.Id).Events, e => e.Kind == "uncertaintyAcknowledged");
      await client.SendAsync(chat.Definition.Id, Guid.NewGuid().ToString(), "continue", cancellationToken: timeout.Token);
      await Until(() => Task.FromResult(core.Get(chat.Definition.Id).Events.Any(e => e.Kind == "message" && e.Text == "exact conversation resumed")), timeout.Token);
      await client.EndAsync(chat.Definition.Id, timeout.Token); Assert.True(client.Get(chat.Definition.Id).Ended); Assert.NotEmpty(client.Get(chat.Definition.Id).Events);
      Assert.Equal(ProcessPresence.Dead, (await processes.ObserveAsync(ChatSessions.Session(client.Get(chat.Definition.Id)), timeout.Token)).Presence);
    }
    finally
    {
      if (chat is not null && !core.Get(chat.Definition.Id).Ended) try { await processes.QuitAsync(chat.CreationKey, CancellationToken.None); } catch (IOException) { }
      serving.Cancel(); await server; await core.DisposeAsync();
      await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2"); Directory.Delete(root.DirectoryPath, true);
    }
  }
  private sealed class SyntheticAccount : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fixture@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("Synthetic accounts do not sign in.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
}
