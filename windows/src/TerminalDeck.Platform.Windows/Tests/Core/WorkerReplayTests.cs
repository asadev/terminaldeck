using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.WorkerCore.Tests;

public sealed class WorkerReplayTests
{
  private static SessionRecord Row() => new(new(Guid.NewGuid().ToString(), "shell", Path.GetTempPath(), "Test"), Guid.NewGuid().ToString("N"), SessionState.Running, "lease", "old", HasStarted: true);
  [Fact]
  public async Task WorkerReconnectReplacesReplayAndPublishesOneResetPastBoundary()
  {
    var row = Row(); var keeper = new SessionKeeper(new Store(row), new NoProcesses());
    await using var attachment = await keeper.AttachAsync(row.Definition.Id);
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "old plus new", false, null);
    await keeper.AppendOutputAsync(row.Definition.Id, " final");
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(3));
    var replay = new SessionReplay(); replay.Restore(attachment.Snapshot);
    await using var events = attachment.Events(ct.Token).GetAsyncEnumerator();
    Assert.True(await events.MoveNextAsync()); Assert.Equal("reset", events.Current.Kind); replay.Receive(events.Current);
    Assert.True(await events.MoveNextAsync()); replay.Receive(events.Current);
    Assert.Equal("old plus new final", replay.Text); Assert.Equal(replay.Text, keeper.Get(row.Definition.Id).Replay);
  }
  [Fact]
  public async Task StaleWorkerCannotOverwriteCurrentLease()
  {
    var row = Row(); var keeper = new SessionKeeper(new Store(row), new NoProcesses());
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "stale-lease", "wrong", true, 9);
    Assert.Equal(row, keeper.Get(row.Definition.Id));
  }
  [Fact]
  public async Task WorkerExitPreservesReplayAndRejectsFurtherInput()
  {
    var row = Row(); var keeper = new SessionKeeper(new Store(row), new NoProcesses());
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "last output", true, 0);
    Assert.Equal(SessionState.Exited, keeper.Get(row.Definition.Id).State);
    Assert.Equal("last output", keeper.Get(row.Definition.Id).Replay);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.WriteAsync(row.Definition.Id, keeper.Instance, new byte[] { 1 }));
  }
  [Fact]
  public async Task FinishedWorkerCanFlushAndBeExplicitlyClosedWithoutAcceptingInput()
  {
    var row = Row(); var processes = new ClosingProcesses(); var keeper = new SessionKeeper(new Store(row), processes);
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "final", true, 0);
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "final frame", true, 0);
    Assert.Equal("final frame", keeper.Get(row.Definition.Id).Replay);
    await keeper.StopAsync(row.Definition.Id, keeper.Instance);
    Assert.Equal("lease", processes.ClosedLease); Assert.Null(keeper.Get(row.Definition.Id).LeaseIdentity);
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "late", true, 0);
    Assert.Equal("final frame", keeper.Get(row.Definition.Id).Replay);
  }
  private sealed class ClosingProcesses : ISessionProcessKeeper
  {
    public string? ClosedLease;
    public ValueTask QuitAsync(string lease, CancellationToken ct) { ClosedLease = lease; return ValueTask.CompletedTask; }
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => throw new NotSupportedException();
  }
  private sealed class Store(SessionRecord row) : IStateStore<SessionLedger>
  {
    private SessionLedger state = new(1, 10, [row]);
    public SessionLedger Load() => state;
    public void Save(SessionLedger next) => state = next;
  }
  private sealed class NoProcesses : ISessionProcessKeeper
  {
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask QuitAsync(string lease, CancellationToken ct) => throw new NotSupportedException();
  }
}
