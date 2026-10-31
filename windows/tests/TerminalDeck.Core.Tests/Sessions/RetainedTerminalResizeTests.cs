using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class RetainedTerminalResizeTests
{
  [Theory] [InlineData(SessionState.Exited)] [InlineData(SessionState.Held)] [InlineData(SessionState.Starting)]
  public async Task ShowingRetainedTerminalDoesNotResizeMissingLeaseOrReportDisconnect(SessionState state)
  {
    var definition = new SessionDefinition(Guid.NewGuid().ToString(), "shell", "C:\\work", "Retained");
    var row = new SessionRecord(definition, "creation", state);
    var store = new MemoryState<SessionLedger> { Value = new(1, 0, [row]) };
    var processes = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, processes);
    await keeper.ResizeAsync(definition.Id, keeper.Instance, new TerminalSize(120, 40));
    Assert.Empty(processes.Calls); Assert.Equal(row, keeper.Get(definition.Id));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.ResizeAsync(definition.Id, Guid.NewGuid(), new TerminalSize(120, 40)));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.WriteAsync(definition.Id, keeper.Instance, new byte[] { 65 }));
  }
  [Fact] public async Task RunningTerminalStillReceivesResize()
  {
    var processes = new FakeProcessKeeper(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes);
    var row = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "C:\\work", "Live")); processes.Calls.Clear();
    await keeper.ResizeAsync(row.Definition.Id, keeper.Instance, new TerminalSize(120, 40));
    Assert.Equal("resize:" + row.LeaseIdentity, Assert.Single(processes.Calls));
  }
}
