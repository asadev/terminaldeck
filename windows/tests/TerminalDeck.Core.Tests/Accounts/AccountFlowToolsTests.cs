using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class AccountFlowToolsTests
{
  [Theory]
  [InlineData("accounts.install", "state", false)]
  [InlineData("accounts.sign_in_flow", "state", false)]
  [InlineData("accounts.install", "cancel", true)]
  [InlineData("accounts.sign_in_flow", "cancel", true)]
  public async Task ProgressReadsAreFreeAndCancellationRequiresTheExistingApproval(string tool, string action, bool approval)
  {
    var permission = new FakePermission(); var door = new McpDoor(permission);
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]);
    var account = await accounts.CreateAsync("claude", "Test"); var calls = new List<string>();
    AccountFlowTools.Register(door, accounts, _ => throw new Exception("A progress read must never install anything."),
      (_, operation) => { calls.Add(operation); return Task.FromResult(JsonSerializer.SerializeToElement(new { state = "waiting" })); },
      (_, operation) => { calls.Add(operation); return Task.FromResult(JsonSerializer.SerializeToElement(new { state = "waiting" })); });
    var caller = door.RegisterCaller(McpTests.Grant(tool), (_, _, _, _, _) => ValueTask.FromResult(true));
    var args = tool == "accounts.install" ? JsonSerializer.SerializeToElement(new { provider = "claude", action }) : JsonSerializer.SerializeToElement(new { accountId = account.Id, action });
    await door.CallAsync(caller.Id, tool, args);
    Assert.Equal(action, Assert.Single(calls)); Assert.Equal(approval ? 1 : 0, permission.Requests.Count);
  }
  [Fact]
  public async Task DeniedCancellationNeverReachesTheLoginWindow()
  {
    var permission = new FakePermission { Answer = r => new(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false) };
    var door = new McpDoor(permission); var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]); var account = await accounts.CreateAsync("claude", "Test");
    var called = false;
    AccountFlowTools.Register(door, accounts, _ => throw new Exception(), (_, _) => throw new Exception(), (_, _) => { called = true; throw new Exception(); });
    var caller = door.RegisterCaller(McpTests.Grant("accounts.sign_in_flow"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "accounts.sign_in_flow", JsonSerializer.SerializeToElement(new { accountId = account.Id, action = "cancel" })));
    Assert.False(called);
  }
  [Fact]
  public async Task InstallationUsesOneApprovalAndNeverRunsFromARead()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission); var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]); await accounts.CreateAsync("claude", "Test"); var installs = 0;
    AccountFlowTools.Register(door, accounts, _ => { installs++; return Task.CompletedTask; }, (_, _) => Task.FromResult(JsonSerializer.SerializeToElement(new { state = "idle" })), (_, _) => throw new Exception());
    var caller = door.RegisterCaller(McpTests.Grant("accounts.install"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "accounts.install", JsonSerializer.SerializeToElement(new { provider = "claude", action = "state" })); Assert.Equal(0, installs);
    await door.CallAsync(caller.Id, "accounts.install", JsonSerializer.SerializeToElement(new { provider = "claude" })); Assert.Equal(1, installs); Assert.Single(permission.Requests);
  }
}
