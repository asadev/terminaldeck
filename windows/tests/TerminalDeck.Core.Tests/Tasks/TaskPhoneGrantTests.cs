using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskPhoneGrantTests
{
  [Fact] public void PairingDoesNotGrantTasksAndProjectScopeUsesWholeFolders()
  {
    var f = new TaskFixture(); var persistence = new MemoryStore<TaskPhoneGrantState>(); var grants = new TaskPhoneGrants(persistence, f.Projects);
    var device = new ApprovedDevice("phone", "Synthetic phone", "ios", PhoneAccess.Full);
    Assert.False(grants.Allows(device, "C:/Work/Sample"));
    grants.Set(new("phone", ["sample"]));
    Assert.True(grants.Allows(device, "c:/work/sample")); Assert.True(grants.Allows(device, "C:/Work/Sample/feature"));
    Assert.False(grants.Allows(device, "C:/Work/Sample-other")); Assert.False(grants.Allows(device, "C:/Work/Other"));
    Assert.True(new TaskPhoneGrants(persistence, f.Projects).Allows(device, "C:/Work/Sample"));
    grants.Set(new("phone", [])); Assert.False(grants.Allows(device, "C:/Work/Sample"));
  }
}
