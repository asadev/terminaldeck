using System.Text;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class StableKeeperShutdownTests
{
  [Fact]
  public async Task ShutdownNeedsAuthenticationAndTheCurrentInstance()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper());
    var secret = new string('s', 64); var called = false;
    var endpoint = new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "fixture", _ => { called = true; return ValueTask.FromResult(true); });
    await Assert.ThrowsAsync<UnauthorizedAccessException>(async () => await endpoint.HandleAsync(new() { Secret = new string('x', 64), Operation = "shutdown-idle", Instance = keeper.Instance }));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await endpoint.HandleAsync(new() { Secret = secret, Operation = "shutdown-idle", Instance = Guid.NewGuid() }));
    Assert.False(called);
    Assert.True((await endpoint.HandleAsync(new() { Secret = secret, Operation = "shutdown-idle", Instance = keeper.Instance })).Success);
    Assert.True(called);
  }

  [Fact]
  public async Task UnsupportedOrBusyKeeperCannotBeStopped()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper());
    var secret = new string('s', 64);
    var request = new KeeperRequest { Secret = secret, Operation = "shutdown-idle", Instance = keeper.Instance };
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "fixture").HandleAsync(request));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "fixture", _ => ValueTask.FromResult(false)).HandleAsync(request));
  }
}
