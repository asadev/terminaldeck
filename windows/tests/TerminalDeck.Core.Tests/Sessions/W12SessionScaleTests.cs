using TerminalDeck.Core.Sessions;
namespace TerminalDeck.Core.Tests.Sessions;
public sealed class W12SessionScaleTests
{
  [Fact] public async Task MoreThan256NormalSessionsHaveNoArtificialCapAndRecoveryOnlyAdoptsLeases()
  {
    // Fake leases prove keeper behavior without opening real processes or
    // presenting this logical test as an idle-CPU measurement.
    var store = new MemoryState<SessionLedger>(); var processes = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, processes);
    for (var i = 0; i < 257; i++) await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "C:\\fixture", "Fixture " + i));
    Assert.Equal(257, keeper.List().Count); Assert.All(keeper.List(), s => Assert.Equal(SessionState.Running, s.State)); Assert.Equal(257, processes.Leases.Count);
    var leases = keeper.List().Select(s => s.LeaseIdentity).ToArray(); processes.Calls.Clear();
    var restored = new SessionKeeper(store, processes); await restored.RecoverAsync();
    Assert.Equal(leases, restored.List().Select(s => s.LeaseIdentity)); Assert.Equal(257, processes.Leases.Count); Assert.All(processes.Calls, call => Assert.StartsWith("observe:", call));
  }
}
