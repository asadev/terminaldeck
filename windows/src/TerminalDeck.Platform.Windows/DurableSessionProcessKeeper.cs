using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public sealed class DurableSessionProcessKeeper(AppDataRoot root, string keeperExecutable, WindowsProviderLaunchPlanner planner,
  ReadOnlyMemory<byte> credential) : ISessionProcessKeeper
{
  public event Action<SessionRecord>? Started;
  private readonly string secret = Encoding.UTF8.GetString(credential.Span);
  public async ValueTask<WorkerSnapshot> SnapshotAsync(string key, CancellationToken ct = default)
  {
    var reply = await SendAsync(key, new() { Secret = secret, CreationKey = key, Operation = "snapshot" }, ct);
    var snapshot = reply.Snapshot ?? throw new IOException("The session worker did not return a snapshot.");
    if (snapshot.CreationKey != key) throw new IOException("The session worker identity changed.");
    return snapshot;
  }
  public async ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct)
  {
    try
    {
      var snapshot = await SnapshotAsync(session.CreationKey, ct);
      if (snapshot.SessionId != session.Definition.Id) return new(ProcessPresence.Unknown);
      return new(ProcessPresence.Live, session.CreationKey,
        ForegroundBusy: false, BackgroundChildren: Math.Max(0, snapshot.ActiveProcesses - (snapshot.RootExited ? 0 : 1)), ActivityKnown: snapshot.RootExited);
    }
    catch (Exception ex) when (ex is IOException or TimeoutException)
    {
      var path = WorkerPaths.PathFor(root, session.CreationKey, ".identity.json");
      if (!File.Exists(path))
      {
        // An unacknowledged create can repeat under the same key: the worker's
        // exclusive lifetime lock prevents two terminals even if an earlier
        // child is still starting. A previously acknowledged lease stays held.
        return new(session.HasStarted ? ProcessPresence.Unknown : ProcessPresence.Dead);
      }
      WorkerIdentity? identity;
      try { identity = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(path)); }
      catch (Exception e) when (e is IOException or JsonException) { return new(ProcessPresence.Unknown); }
      if (identity is null || identity.CreationKey != session.CreationKey || identity.SessionId != session.Definition.Id) return new(ProcessPresence.Unknown);
      try
      {
        using var process = Process.GetProcessById(identity.Pid);
        return new(process.StartTime.ToUniversalTime().Ticks == identity.StartedUtcTicks && !process.HasExited ? ProcessPresence.Unknown : ProcessPresence.Dead);
      }
      catch (ArgumentException) { return new(ProcessPresence.Dead); }
      catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { return new(ProcessPresence.Unknown); }
    }
  }
  public async ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct)
  {
    WindowsPrivateDirectory.Ensure(WorkerPaths.DirectoryFor(root));
    // Cross-process exclusive file ownership serializes repeat creates. No await-held thread mutex.
    await using var creation = new FileStream(WorkerPaths.PathFor(root, session.CreationKey, ".create"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    var before = await ObserveAsync(session, ct);
    if (before.Presence != ProcessPresence.Dead) return before;
    // A previously started worker is never recreated under the same lease.
    if (File.Exists(WorkerPaths.PathFor(root, session.CreationKey, ".identity.json"))) return before;
    await using var serverLease = session.Definition.ServerId is { } serverId
      ? await new TerminalDeck.Platform.Windows.Servers.WindowsOpenSshRuntime(root, new WindowsCredentialStore(root),
          Path.Combine(Path.GetDirectoryName(keeperExecutable)!, "askpass", "TerminalDeck.Servers.Askpass.exe"))
        .PrepareTerminalAsync(new TerminalDeck.Core.Servers.ServerStore(root, new WindowsCredentialStore(root)).List().Single(s => s.Id == serverId), ct)
      : null;
    var launch = new WorkerLaunch(session, serverLease?.Launch ?? planner.Plan(session, resume), new(100, 30));
    var bytes = JsonSerializer.SerializeToUtf8Bytes(launch);
    var planPath = WorkerPaths.PathFor(root, session.CreationKey, ".launch"); var temporary = planPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      File.WriteAllBytes(temporary, new CurrentUserDpapi(root).Protect(bytes)); File.Move(temporary, planPath, overwrite: true);
    }
    finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); if (File.Exists(temporary)) File.Delete(temporary); }
    DetachedProcess.Start(keeperExecutable, ["--user-data-dir", root.DirectoryPath, "--worker", session.CreationKey], Path.GetDirectoryName(keeperExecutable)!);
    // Startup has a deadline, not a guess based on a stored PID.
    for (var attempt = 0; attempt < 12; attempt++)
    {
      ct.ThrowIfCancellationRequested();
      var observation = await ObserveAsync(session, ct);
      if (observation.Presence == ProcessPresence.Live)
      {
        if (serverLease is not null) await serverLease.Handshake.WaitAsync(ct);
        Started?.Invoke(session); return observation;
      }
      await Task.Delay(100, ct);
    }
    return new(ProcessPresence.Unknown, session.CreationKey);
  }
  public async ValueTask WriteAsync(string leaseIdentity, ReadOnlyMemory<byte> bytes, CancellationToken ct)
  {
    if (bytes.Length > KeeperWire.MaximumInputBytes) throw new ArgumentException("That input is too large.");
    await RequireSuccessAsync(leaseIdentity, new() { Secret = secret, CreationKey = leaseIdentity, Operation = "write", Bytes = bytes.ToArray() }, ct);
  }
  public async ValueTask ResizeAsync(string leaseIdentity, TerminalSize size, CancellationToken ct)
  {
    size.Validate(); await RequireSuccessAsync(leaseIdentity, new() { Secret = secret, CreationKey = leaseIdentity, Operation = "resize", Size = size }, ct);
  }
  public async ValueTask QuitAsync(string leaseIdentity, CancellationToken ct) => await RequireSuccessAsync(leaseIdentity,
    new() { Secret = secret, CreationKey = leaseIdentity, Operation = "quit" }, ct);
  private async ValueTask RequireSuccessAsync(string key, WorkerRequest request, CancellationToken ct)
  {
    if ((await SendAsync(key, request, ct)).Success != true) throw new IOException("The session worker refused this request.");
  }
  private async ValueTask<WorkerMessage> SendAsync(string key, WorkerRequest request, CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(10));
    await using var pipe = await WorkerPaths.ConnectAsync(root, key, deadline.Token);
    await KeeperWire.WriteAsync(pipe, request, cancellationToken: deadline.Token);
    return await KeeperWire.ReadAsync<WorkerMessage>(pipe, true, deadline.Token);
  }
  public async Task FollowAsync(SessionRecord session, SessionKeeper keeper, TaskCompletionSource ready, CancellationToken ct)
  {
    try
    {
      await using var pipe = await WorkerPaths.ConnectAsync(root, session.CreationKey, ct);
      await KeeperWire.WriteAsync(pipe, new WorkerRequest { Secret = secret, CreationKey = session.CreationKey, Operation = "watch" }, cancellationToken: ct);
      var initial = (await KeeperWire.ReadAsync<WorkerMessage>(pipe, true, ct)).Snapshot ?? throw new IOException("The worker snapshot is missing.");
      if (initial.CreationKey != session.CreationKey || initial.SessionId != session.Definition.Id) throw new IOException("The worker identity changed.");
      await keeper.RestoreWorkerReplayAsync(initial.SessionId, initial.CreationKey, initial.Replay, initial.ActiveProcesses == 0, initial.ExitCode, ct);
      ready.TrySetResult(); var sequence = initial.Sequence;
      await foreach (var change in Events(pipe, ct))
      {
        if (change.Sequence <= sequence) continue;
        if (change.Sequence != sequence + 1 || change.Id != initial.SessionId) throw new IOException("The worker stream needs a fresh snapshot.");
        sequence = change.Sequence;
        if (change.Kind == "data") await keeper.AppendWorkerOutputAsync(change.Id, session.CreationKey, change.Text ?? "", ct);
        else
        {
          var status = await SnapshotAsync(session.CreationKey, ct);
          // A status snapshot can include output still queued on this pipe. Ignore
          // that output through its boundary so reconnect never duplicates it.
          await keeper.RestoreWorkerReplayAsync(status.SessionId, status.CreationKey, status.Replay, status.ActiveProcesses == 0, status.ExitCode, ct);
          sequence = status.Sequence;
        }
      }
    }
    catch (Exception ex) when (ex is IOException or OperationCanceledException or TimeoutException)
    { ready.TrySetException(new IOException("The terminal worker needs to reconnect.")); }
  }
  private static async IAsyncEnumerable<SessionEvent> Events(Stream pipe, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
  {
    while (!ct.IsCancellationRequested)
    {
      var reply = await KeeperWire.ReadAsync<WorkerMessage>(pipe, true, ct);
      yield return reply.Event ?? throw new IOException("The worker event stream ended.");
    }
  }
}
