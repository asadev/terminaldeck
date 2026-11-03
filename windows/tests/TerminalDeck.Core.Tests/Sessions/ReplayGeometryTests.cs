using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class ReplayGeometryTests
{
  [Fact] public async Task ReconnectCarriesActualWorkerGeometryWithoutResizingItsProcess()
  {
    var row = Row(); var processes = new Processes(); var keeper = new SessionKeeper(new Store(row), processes);
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "\u001b[2;1H❯ half typed", false, null, replaySize: new(100, 30));
    await using var attachment = await keeper.AttachAsync(row.Definition.Id);
    Assert.Equal(new TerminalSize(100, 30), attachment.Snapshot.Session.ReplaySize);
    Assert.Empty(processes.Sizes);
    await keeper.ResizeAsync(row.Definition.Id, keeper.Instance, new(82, 24));
    Assert.Equal(new[] { new TerminalSize(82, 24) }, processes.Sizes);
    Assert.Equal(new TerminalSize(82, 24), keeper.Get(row.Definition.Id).ReplaySize);
  }
  [Fact] public async Task UnknownWorkerConnectionIsHeldAndRecoversSameLeaseWithoutRestart()
  {
    var row = Row(); var processes = new Processes(); var keeper = new SessionKeeper(new Store(row), processes);
    await keeper.WorkerConnectionLostAsync(row.Definition.Id, "stale"); Assert.Equal(SessionState.Running, keeper.Get(row.Definition.Id).State);
    await keeper.WorkerConnectionLostAsync(row.Definition.Id, "lease"); Assert.Equal(SessionState.Held, keeper.Get(row.Definition.Id).State);
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "kept output", false, null, replaySize: new(120, 40));
    Assert.Equal(SessionState.Running, keeper.Get(row.Definition.Id).State);
    Assert.Equal("lease", keeper.Get(row.Definition.Id).LeaseIdentity); Assert.Equal("kept output", keeper.Get(row.Definition.Id).Replay); Assert.Equal(0, processes.Starts);
  }
  [Fact] public async Task StaleWorkerCannotReplaceReplayGeometryAndRepeatedSizeDoesNotPublishReset()
  {
    var row = Row(); var keeper = new SessionKeeper(new Store(row), new Processes());
    await keeper.RestoreWorkerReplayAsync(row.Definition.Id, "lease", "kept", false, null, replaySize: new(100, 30));
    await keeper.RecordWorkerSizeAsync(row.Definition.Id, "wrong", new(80, 20));
    await using var watch = await keeper.AttachAsync(row.Definition.Id);
    await keeper.RecordWorkerSizeAsync(row.Definition.Id, "lease", new(100, 30));
    await keeper.RecordWorkerSizeAsync(row.Definition.Id, "lease", new(90, 25));
    using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(3));
    await using var events = watch.Events(stop.Token).GetAsyncEnumerator();
    Assert.True(await events.MoveNextAsync()); Assert.Equal("geometry", events.Current.Kind); Assert.Equal(new TerminalSize(90, 25), events.Current.ReplaySize);
    Assert.Equal(watch.Snapshot.Sequence + 1, events.Current.Sequence); Assert.Equal("kept", keeper.Get(row.Definition.Id).Replay);
  }
  private static SessionRecord Row() => new(new(Guid.NewGuid().ToString(), "shell", Path.GetTempPath(), "Synthetic"), Guid.NewGuid().ToString("N"), SessionState.Running, "lease", HasStarted: true);
  private sealed class Store(SessionRecord row) : IStateStore<SessionLedger>
  {
    private SessionLedger state = new(1, 1, [row]);
    public SessionLedger Load() => state;
    public void Save(SessionLedger value) => state = value;
  }
  private sealed class Processes : ISessionProcessKeeper
  {
    public readonly List<TerminalSize> Sizes = []; public int Starts;
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Unknown));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct) { Starts++; throw new InvalidOperationException("Must not start a replacement."); }
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) { Sizes.Add(size); return ValueTask.CompletedTask; }
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask QuitAsync(string lease, CancellationToken ct) => ValueTask.CompletedTask;
  }
}
