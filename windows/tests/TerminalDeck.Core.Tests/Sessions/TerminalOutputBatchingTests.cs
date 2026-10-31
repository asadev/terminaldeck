using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Sessions;

// Umer's "typing lands one letter back after a while": per-chunk ledger saves
// made the keeper fall behind busy sessions, and every overflowed watch forced a
// full replay in the app. Output saving is batched and the watch buffer is deep.
public sealed class TerminalOutputBatchingTests
{
  private sealed class CountingState : IStateStore<SessionLedger>
  {
    private readonly object gate = new();
    public SessionLedger? Value; public int Saves;
    public SessionLedger? Load() { lock (gate) return Value; }
    public void Save(SessionLedger value) { lock (gate) { Value = value; Saves++; } }
  }
  private static SessionDefinition Definition() => new(Guid.NewGuid().ToString(), "claude", "C:\\work", "A session", ConversationId: "conversation-1");

  [Fact] public async Task WorkerOutputIsSavedInBatchesAndStateChangesStillSaveItAtOnce()
  {
    var store = new CountingState(); var keeper = new SessionKeeper(store, new FakeProcessKeeper());
    var row = await keeper.CreateAsync(Definition()); var before = store.Saves;
    for (var i = 0; i < 500; i++) await keeper.AppendWorkerOutputAsync(row.Definition.Id, row.LeaseIdentity!, "x");
    Assert.True(store.Saves - before <= 1, $"{store.Saves - before} saves for 500 chunks");
    Assert.Equal(500, keeper.Get(row.Definition.Id).Replay.Length); // live state is current at once

    await keeper.RenameAsync(row.Definition.Id, "Renamed");
    Assert.Equal(500, store.Value!.Sessions.Single().Replay.Length); // a state change saves the newest output too
  }

  [Fact] public async Task BatchedOutputReachesDiskWithoutAnyStateChange()
  {
    var store = new CountingState(); var keeper = new SessionKeeper(store, new FakeProcessKeeper());
    var row = await keeper.CreateAsync(Definition());
    await keeper.AppendWorkerOutputAsync(row.Definition.Id, row.LeaseIdentity!, "hello");
    var deadline = DateTime.UtcNow + SessionKeeper.OutputSaveInterval + TimeSpan.FromSeconds(5);
    while (store.Value!.Sessions.Single().Replay != "hello" && DateTime.UtcNow < deadline) await Task.Delay(50);
    Assert.Equal("hello", store.Value!.Sessions.Single().Replay);
    await keeper.AppendWorkerOutputAsync(row.Definition.Id, row.LeaseIdentity!, " world"); keeper.FlushOutput();
    Assert.Equal("hello world", store.Value!.Sessions.Single().Replay);
    Assert.Equal("hello world", new SessionKeeper(store, new FakeProcessKeeper()).Get(row.Definition.Id).Replay);
  }

  [Fact] public async Task AWatcherThatFallsBehindByThousandsOfChunksKeepsItsStream()
  {
    var keeper = new SessionKeeper(new CountingState(), new FakeProcessKeeper()); var row = await keeper.CreateAsync(Definition());
    await using var attach = await keeper.AttachAsync(row.Definition.Id);
    for (var i = 0; i < 2000; i++) await keeper.AppendWorkerOutputAsync(row.Definition.Id, row.LeaseIdentity!, "x");
    Assert.False(attach.Closed);
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(5)); var received = 0;
    await foreach (var change in attach.Events(ct.Token)) { Assert.Equal("data", change.Kind); if (++received == 2000) break; }
    Assert.Equal(2000, received);
  }
}
