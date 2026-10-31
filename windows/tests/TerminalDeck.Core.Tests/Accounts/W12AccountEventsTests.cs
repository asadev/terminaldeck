using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class W12AccountEventsTests
{
  [Fact]
  public async Task RenameNotifiesOnlyAfterPersistenceAndPreservesIdentity()
  {
    var store = new MemoryState<AccountState>(); var service = new AccountService(store, [new FakeAccountProvider("codex")]);
    var account = await service.CreateAsync("codex", "Work"); var observed = new List<AccountProfile>();
    service.Changed += () => observed.Add(service.Get(account.Id));
    await service.RenameAsync(account.Id, "New name");
    var changed = Assert.Single(observed);
    Assert.Equal(account with { Name = "New name" }, changed);
    Assert.Equal(changed, Assert.Single(store.Value!.Accounts));
    store.FailSave = true;
    await Assert.ThrowsAsync<IOException>(async () => await service.RenameAsync(account.Id, "Unsaved"));
    Assert.Single(observed); Assert.Equal("New name", service.Get(account.Id).Name);
  }
  [Fact]
  public async Task MissingInstallationAdapterIsUnknownAndNeverInventsAnInstalledTool()
  {
    var service = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]);
    var row = await service.CreateAsync("codex", "Work");
    var installation = await service.InstallationAsync(row.Id);
    Assert.Null(installation.Installed); Assert.Null(installation.Version);
    Assert.False(service.Get(row.Id).SignedIn);
  }
  [Fact]
  public async Task InstallationReadUsesAccountGrantWithoutApprovalOrSignIn()
  {
    var provider = new InstallationProvider();
    var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var row = await service.CreateAsync("codex", "Work");
    var permissions = new TerminalDeck.Core.Tests.Mcp.FakePermission();
    var door = new TerminalDeck.Core.Mcp.McpDoor(permissions);
    TerminalDeck.Core.Mcp.DeckCoreTools.RegisterAccounts(door, service,
      new TerminalDeck.Core.Sessions.SessionKeeper(new MemoryState<TerminalDeck.Core.Sessions.SessionLedger>(), new FakeProcessKeeper()));
    var grant = TerminalDeck.Core.Tests.Mcp.McpTests.Grant("accounts.status") with { Resources = ["accounts:" + row.Id] };
    var caller = door.RegisterCaller(grant, (_, _, _, _, _) => ValueTask.FromResult(true));
    var result = await door.CallAsync(caller.Id, "accounts.status", System.Text.Json.JsonSerializer.SerializeToElement(new { accountId = row.Id, installation = true }));
    Assert.Equal("1.2.3", result.GetProperty("installation").GetProperty("Version").GetString());
    Assert.Empty(permissions.Requests); Assert.Equal(1, provider.Reads); Assert.Empty(provider.Inner.Calls);
    var outsider = door.RegisterCaller(grant with { Resources = ["accounts:other"] }, (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<TerminalDeck.Core.Mcp.McpRefusal>(async () => await door.CallAsync(outsider.Id, "accounts.status", System.Text.Json.JsonSerializer.SerializeToElement(new { accountId = row.Id, installation = true })));
    Assert.Equal(1, provider.Reads);
  }
  [Fact]
  public async Task ProfileAndDefaultMutationsNotifyObserversButUnchangedStatusDoesNot()
  {
    var provider = new FakeAccountProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var count = 0; service.Changed += () => count++;
    var row = await service.CreateAsync("codex", "Work"); Assert.Equal(1, count);
    await service.RefreshAsync(row.Id); Assert.Equal(1, count);
    await service.SetDefaultAsync("codex", row.Id); Assert.Equal(2, count);
    await service.ShareHistoryAsync(row.Id, true); Assert.Equal(3, count);
    await service.DeleteAsync(row.Id, _ => false); Assert.Equal(4, count);
  }
  private sealed class InstallationProvider : IAccountProvider, IAccountInstallation
  {
    public FakeAccountProvider Inner { get; } = new("codex");
    public int Reads { get; private set; }
    public string Provider => "codex";
    public ValueTask<ProviderInstallation> InstallationAsync(AccountProfile account, CancellationToken ct) { Reads++; return ValueTask.FromResult(new ProviderInstallation(true, "1.2.3", DateTimeOffset.UtcNow, "Installed")); }
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => Inner.StatusAsync(account, ct);
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => Inner.SignInAsync(account, folder, ct);
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => Inner.SignOutAsync(account, ct);
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => Inner.ModelsAsync(account, ct);
  }
}
