using System.Collections.Concurrent;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.Keeper;

public sealed class WindowsKeeperRuntime
{
  private readonly AppDataRoot root;
  private readonly byte[] credential;
  private readonly string executable;
  private readonly string toolsDirectory;
  private readonly DurableSessionProcessKeeper processes;
  private readonly ConcurrentDictionary<string, Task> followers = [];
  private readonly ConcurrentDictionary<string, TaskCompletionSource> ready = [];
  public SessionKeeper Sessions { get; }
  public WindowsKeeperRuntime(AppDataRoot root, string executable, string toolsDirectory)
  {
    this.executable = executable; this.toolsDirectory = toolsDirectory;
    this.root = root; WindowsPrivateDirectory.Ensure(Path.Combine(root.DirectoryPath, "keeper"));
    credential = KeeperCredentials.GetOrCreate(root);
    processes = new(root, executable, new(root, toolsDirectory), credential);
    Sessions = new(new JsonStateStore<SessionLedger>(root, "sessions"), processes, new TerminalDeck.Core.Accounts.ConversationFiles(root)) { CurrentLogin = CurrentLogin };
  }
  // Reads the saved accounts each time: a restarted terminal follows its account's
  // current login folder (signing in again can move it), like chats do.
  private string? CurrentLogin(SessionDefinition definition)
  {
    var account = new JsonStateStore<TerminalDeck.Core.Accounts.AccountState>(root, "accounts").Load()?.Accounts.FirstOrDefault(a => a.Id == definition.AccountId);
    return account is { SignedIn: true } && account.Provider == definition.Provider ? account.HomeId : null;
  }
  public async Task RunAsync(CancellationToken ct)
  {
    // Exactly one supervisor per data root. Session and chat workers run the
    // same executable with --worker/--chat-worker and never take this name.
    using var single = new Mutex(false, @"Local\terminaldeck-keeper-" + root.NamespaceId);
    bool owned;
    try { owned = single.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
    if (!owned) throw new IOException("Another keeper already serves this data folder.");
    using var current = System.Diagnostics.Process.GetCurrentProcess();
    using var ownership = new FileStream(Path.Combine(root.DirectoryPath, "keeper", "supervisor.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
    File.WriteAllBytes(Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json"), System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new { Pid = current.Id, StartedUtcTicks = current.StartTime.ToUniversalTime().Ticks }));
    void Follow(SessionRecord session)
    {
      var signal = ready.GetOrAdd(session.CreationKey, _ => new(TaskCreationOptions.RunContinuationsAsynchronously));
      followers.GetOrAdd(session.CreationKey, _ => Task.Run(async () =>
      {
        while (!ct.IsCancellationRequested && Sessions.Get(session.Definition.Id).State != SessionState.Exited && Sessions.Get(session.Definition.Id).CreationKey == session.CreationKey)
        {
          await processes.FollowAsync(session, Sessions, signal, ct);
          // A broken event pipe is the recovery trigger. Prove the exact worker
          // dead before resuming; an unknown/live lease must never duplicate it.
          if (!ct.IsCancellationRequested && Sessions.Get(session.Definition.Id).State != SessionState.Exited &&
            Sessions.Get(session.Definition.Id).CreationKey == session.CreationKey &&
            (await processes.ObserveAsync(session, ct)).Presence == ProcessPresence.Dead)
            await Sessions.RecoverAsync(ct);
          if (!ct.IsCancellationRequested) { try { await Task.Delay(500, ct); } catch (OperationCanceledException) { } }
        }
      }, CancellationToken.None));
    }
    processes.Started += Follow;
    // An exited worker can still hold its final display frame. Import it before
    // serving the first client after a supervisor crash, without resuming it.
    foreach (var row in Sessions.List().Where(r => r.State == SessionState.Exited && r.LeaseIdentity is not null))
    {
      try
      {
        var snapshot = await processes.SnapshotAsync(row.CreationKey, ct);
        if (snapshot.SessionId == row.Definition.Id && snapshot.ActiveProcesses == 0)
          await Sessions.RestoreWorkerReplayAsync(row.Definition.Id, row.LeaseIdentity!, snapshot.Replay, true, snapshot.ExitCode, ct);
      }
      catch (Exception ex) when (ex is IOException or TimeoutException) { }
    }
    await Sessions.RecoverAsync(ct);
    foreach (var row in Sessions.List().Where(r => r.State == SessionState.Running)) Follow(row);
    foreach (var signal in ready.Values) await signal.Task.WaitAsync(TimeSpan.FromSeconds(15), ct);
    var accountProviders = new[] { "claude", "codex", "gemini" }.Select(p => new WindowsAccountProvider(p, root, toolsDirectory, async (account, folder) =>
    {
      await Sessions.CreateAsync(new(Guid.NewGuid().ToString(), account.Provider, folder, "Sign in · " + account.Name, account.Id, account.HomeId, Purpose: "sign-in"), ct);
    }));
    var accounts = new TerminalDeck.Core.Accounts.AccountService(new JsonStateStore<TerminalDeck.Core.Accounts.AccountState>(root, "accounts"), accountProviders);
    _ = accounts.WarmModelsAsync(ct);
    await using var chats = new TerminalDeck.Core.Chats.ChatSessions(new TerminalDeck.Core.Chats.ChatHistory(root), new TerminalDeck.Platform.Windows.Chats.WindowsChatProcessKeeper(root, executable, toolsDirectory, credential), accounts);
    var savedHoot = TerminalDeck.Core.Hoot.HootStorage.At(root).Load();
    foreach (var chat in TerminalDeck.Core.Hoot.HootChatRecovery.OrdinaryChats(chats.List(), savedHoot))
      await chats.ReconnectAsync(chat.Definition.Id, ct);
    var tools = new TerminalDeck.Platform.Windows.Integration.HootToolConnection(root, credential);
    await using var hoot = new TerminalDeck.Core.Hoot.HootService(TerminalDeck.Core.Hoot.HootStorage.At(root), chats, accounts,
      new KeeperHootHandoff(Sessions, chats), prepareTools: tools.PrepareAsync, ready: TerminalDeck.Core.Hoot.HootReady.For(root, p => TerminalDeck.Core.Settings.GeneralSettings.NewChatPermission(root, p)));
    using var serving = CancellationTokenSource.CreateLinkedTokenSource(ct);
    var chatPipe = new TerminalDeck.Platform.Windows.Chats.ChatSessionsPipeServer(root, chats, credential).RunAsync(serving.Token);
    // Ended terminal workers retain a final replay frame. Save it before
    // releasing their package files; never quit a worker with live children.
    async ValueTask<bool> ReleaseEndedWorkers(CancellationToken shutdown)
    {
      foreach (var row in Sessions.List().Where(r => r.State == SessionState.Exited))
      {
        var identityPath = WorkerPaths.PathFor(root, row.CreationKey, ".identity.json");
        if (!File.Exists(identityPath)) continue;
        var worker = System.Text.Json.JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(identityPath));
        if (worker is null || worker.SessionId != row.Definition.Id || worker.CreationKey != row.CreationKey) return false;
        try
        {
          using var owned = System.Diagnostics.Process.GetProcessById(worker.Pid);
          if (owned.HasExited || owned.StartTime.ToUniversalTime().Ticks != worker.StartedUtcTicks) continue;
        }
        catch (ArgumentException) { continue; }
        var snapshot = await processes.SnapshotAsync(row.CreationKey, shutdown);
        if (snapshot.ActiveProcesses != 0 || snapshot.SessionId != row.Definition.Id) return false;
        await Sessions.RestoreWorkerReplayAsync(row.Definition.Id, row.CreationKey, snapshot.Replay, true, snapshot.ExitCode, shutdown);
        await processes.QuitAsync(row.CreationKey, shutdown);
      }
      return true;
    }
    async ValueTask<bool> ShutdownIdle(CancellationToken shutdown)
    {
      if (!StableChannel.IsStable(AppContext.BaseDirectory) || Sessions.List().Any(s => s.State != SessionState.Exited) || chats.List().Any(c => !c.Ended)) return false;
      if (!await ReleaseEndedWorkers(shutdown)) return false;
      // Let the authenticated response flush before releasing the supervisor.
      serving.CancelAfter(TimeSpan.FromMilliseconds(250));
      return true;
    }
    // Update handover: save every session and chat for the next version, retire
    // all workers, then exit so Windows can replace the package. The next
    // keeper's normal recovery restarts them (conversations resume).
    async ValueTask<int> PrepareUpdate(CancellationToken shutdown)
    {
      int count;
      try
      {
        count = await Sessions.PrepareUpdateAsync(shutdown) + await chats.PrepareUpdateAsync(shutdown);
        if (!await ReleaseEndedWorkers(shutdown)) throw new IOException("An ended terminal is still running a program, so the update was not applied.");
      }
      catch
      {
        // Nothing is lost: restart whatever was already handed over, here.
        Sessions.CancelUpdate();
        try { await Sessions.RecoverAsync(CancellationToken.None); foreach (var row in Sessions.List().Where(r => r.State == SessionState.Running)) Follow(row); } catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
        throw;
      }
      serving.CancelAfter(TimeSpan.FromMilliseconds(250));
      return count;
    }
    var terminalPipe = new KeeperPipeServer(root, new(Sessions, credential, "0.1.0-windows", ShutdownIdle, PrepareUpdate)).RunAsync(serving.Token);
    var hootPipe = new TerminalDeck.Platform.Windows.Hoot.HootPipeServer(root, hoot, credential).RunAsync(serving.Token);
    var taskCoordinator = new TerminalDeck.Platform.Windows.Tasks.KeeperTaskCoordinator(root, Sessions, chats, hoot).RunAsync(serving.Token);
    var services = new[] { chatPipe, terminalPipe, hootPipe, taskCoordinator };
    try { await Task.WhenAny(services); }
    finally
    {
      serving.Cancel();
      try { await Task.WhenAll(services); }
      catch (OperationCanceledException) when (serving.IsCancellationRequested) { }
      processes.Started -= Follow;
      Sessions.FlushOutput(); // Output saving is batched; keep the newest replay on a clean exit.
    }
  }
}
