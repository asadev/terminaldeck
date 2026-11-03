using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhonePortOwnershipTests
{
  private static readonly PhonePortRoot Root = new(10, 1000, "synthetic-session");
  private static Dictionary<int, PhonePortProcess> Processes() => new()
  {
    [10] = new(10, 1, 1000), [20] = new(20, 10, 1100), [30] = new(30, 20, 1200), [50] = new(50, 1, 900)
  };
  [Fact] public void WorkCanReachOnlyCurrentlyGrantedSessionDescendants()
  {
    var processes = Processes();
    Assert.True(PhonePortOwnership.Allows(PhoneAccess.Work, [30], [Root], pid => processes.GetValueOrDefault(pid)));
    Assert.False(PhonePortOwnership.Allows(PhoneAccess.Work, [50], [Root], pid => processes.GetValueOrDefault(pid)));
    Assert.False(PhonePortOwnership.Allows(PhoneAccess.Work, [30], [], pid => processes.GetValueOrDefault(pid)));
    Assert.False(PhonePortOwnership.Allows(PhoneAccess.Work, [30, 50], [Root], pid => processes.GetValueOrDefault(pid)));
  }
  [Fact] public void ReusedPidBrokenAncestryAndUnknownOwnerAreDenied()
  {
    var processes = Processes(); processes[10] = new(10, 1, 2000);
    Assert.False(PhonePortOwnership.Allows(PhoneAccess.Work, [30], [Root], pid => processes.GetValueOrDefault(pid)));
    processes = Processes(); processes[20] = new(20, 10, 1500);
    Assert.False(PhonePortOwnership.Allows(PhoneAccess.Work, [30], [Root], pid => processes.GetValueOrDefault(pid)));
    Assert.False(PhonePortOwnership.Allows(PhoneAccess.Work, [], [Root], pid => processes.GetValueOrDefault(pid)));
  }
  [Theory] [InlineData(PhoneAccess.Look)] [InlineData(PhoneAccess.Hoot)]
  public void LowerTiersNeverReachLocalhost(PhoneAccess access) => Assert.False(PhonePortOwnership.Allows(access, [30], [Root], pid => Processes().GetValueOrDefault(pid)));
}
