using TerminalDeck.Core.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class W12ServerRenameTests
{
  [Fact] public async Task OwnerRenameKeepsConnectionCredentialsAndNeedsExactApproval()
  {
    using var f = new Fixture(); var original = await f.AddAsync(); var credential = f.Secrets.Values.Single().Value.ToArray();
    f.Approval.Allow = false;
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.RenameAsync(original.Id, "Renamed", ServerCaller.Person));
    Assert.Equal(original, f.Store.Get(original.Id));
    f.Approval.Allow = true; await f.Service.RenameAsync(original.Id, "  Renamed  ", ServerCaller.Person);
    Assert.Equal(original with { Name = "Renamed" }, f.Store.Get(original.Id)); Assert.Equal(credential, f.Secrets.Values.Single().Value);
    Assert.Equal("Renamed", f.Approval.Actions.Last().Target); Assert.Empty(f.Runtime.Commands);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.RenameAsync(original.Id, "", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.RenameAsync(original.Id, "Other", new("ai", LocalSession: true)));
  }
}
