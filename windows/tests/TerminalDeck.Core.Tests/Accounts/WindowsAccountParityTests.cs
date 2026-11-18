using System.Net;
using System.Text;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class WindowsAccountParityTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-account-parity-" + Guid.NewGuid().ToString("N")));

  [Fact] public async Task RefusedKeyCannotLaunchAndReplacementCanBeCheckedAgain()
  {
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]);
    var response = new Response(HttpStatusCode.Unauthorized);
    var api = new ApiAccountService(accounts, new AccountCredentials(new TestSecretStore(), root), root, new HttpClient(response));
    var account = await api.AddAsync("claude", "Chosen API name", new(ApiKinds.Anthropic), "made-up-test-key");
    await api.CheckAsync(account.Id);
    Assert.False(accounts.Get(account.Id).SignedIn);
    await Assert.ThrowsAsync<ApiAccountUnavailableException>(async () => await accounts.RequireSignedInAsync(account.Id));
    await api.UpdateAsync(account.Id, new(ApiKinds.Anthropic), "replacement-test-key");
    response.Code = HttpStatusCode.OK;
    await api.CheckAsync(account.Id);
    Assert.True((await accounts.RequireSignedInAsync(account.Id)).SignedIn);
    Assert.Equal("Chosen API name", accounts.Get(account.Id).Name);
  }

  [Fact] public async Task MissingCredentialIsDifferentFromAServiceOutage()
  {
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]);
    var credentials = new AccountCredentials(new TestSecretStore(), root);
    var api = new ApiAccountService(accounts, credentials, root, new HttpClient(new Response(HttpStatusCode.ServiceUnavailable)));
    var account = await api.AddAsync("codex", "API", new(ApiKinds.OpenAi), "made-up-test-key");
    Assert.Equal("unavailable", (await api.CheckAsync(account.Id)).CheckState);
    Assert.True(accounts.Get(account.Id).SignedIn);
    await credentials.DeleteAsync(api.Read(account.Id)!.CredentialReference!);
    Assert.Equal("needs-key", (await api.CheckAsync(account.Id)).CheckState);
    Assert.False(accounts.Get(account.Id).SignedIn);
  }

  [Theory]
  [InlineData("Rejected made-up-test-key")]
  [InlineData("Rejected key ending in test-key")]
  public async Task ProviderCannotEchoTheSubmittedKeyIntoSavedStatus(string reason)
  {
    const string key = "made-up-test-key";
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]);
    var api = new ApiAccountService(accounts, new AccountCredentials(new TestSecretStore(), root), root,
      new HttpClient(new Response(HttpStatusCode.Unauthorized, System.Text.Json.JsonSerializer.Serialize(new { error = new { message = reason } }))));
    var account = await api.AddAsync("claude", "API", new(ApiKinds.Anthropic), key);
    var result = await api.CheckAsync(account.Id);
    Assert.Null(result.CheckDetail);
    Assert.Equal("Invalid key", ApiAccountService.Status(result));
    Assert.DoesNotContain(key, File.ReadAllText(ApiAccountFiles.PathFor(root, account.HomeId)));
  }

  [Fact] public async Task NextAccountChoiceRecoversAnInterruptedSwitchWithoutASeparateRecoveryAction()
  {
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]);
    var first = await accounts.CreateAsync("codex", "First API", AccountAuthentication.ApiKey);
    var latest = await accounts.CreateAsync("codex", "Latest API", AccountAuthentication.ApiKey);
    await accounts.SetApiStateAsync(first.Id, true, Guid.NewGuid().ToString("N"));
    await accounts.SetApiStateAsync(latest.Id, true, Guid.NewGuid().ToString("N"));
    var runtime = new FakeAccountRuntime { FailApply = true, FailRollback = true };
    var journal = new MemoryState<AccountSwitchJournal>();
    var switches = new AccountSwitchCoordinator(accounts, runtime, journal);
    await Assert.ThrowsAsync<IOException>(async () => await switches.SwitchAsync("session", first.Id));
    runtime.FailApply = false; runtime.FailRollback = false;
    await switches.SwitchAsync("session", latest.Id);
    Assert.Equal(latest.Id, runtime.Binding.AccountId);
    Assert.Equal("stable-chat", runtime.Binding.ConversationId);
    Assert.All(journal.Value!.Entries, entry => Assert.Equal(SwitchState.Committed, entry.State));
  }

  [Fact] public async Task AnExpiredInterruptedChoiceRollsBackAndTheNewChoiceStillApplies()
  {
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]);
    var expired = await accounts.CreateAsync("codex", "Expired API", AccountAuthentication.ApiKey);
    var latest = await accounts.CreateAsync("codex", "Latest API", AccountAuthentication.ApiKey);
    await accounts.SetApiStateAsync(expired.Id, true, Guid.NewGuid().ToString("N"));
    await accounts.SetApiStateAsync(latest.Id, true, Guid.NewGuid().ToString("N"));
    var runtime = new FakeAccountRuntime { FailApply = true, FailRollback = true };
    var journal = new MemoryState<AccountSwitchJournal>();
    var switches = new AccountSwitchCoordinator(accounts, runtime, journal);
    await Assert.ThrowsAsync<IOException>(async () => await switches.SwitchAsync("session", expired.Id));
    await accounts.SetApiStateAsync(expired.Id, false, Guid.NewGuid().ToString("N"));
    runtime.FailApply = false; runtime.FailRollback = false;
    await switches.SwitchAsync("session", latest.Id);
    Assert.Equal(latest.Id, runtime.Binding.AccountId);
    Assert.Equal("stable-chat", runtime.Binding.ConversationId);
    Assert.Equal(new[] { SwitchState.RolledBack, SwitchState.Committed }, journal.Value!.Entries.Select(entry => entry.State));
  }

  private sealed class Response(HttpStatusCode code, string body = "{}") : HttpMessageHandler
  {
    public HttpStatusCode Code { get; set; } = code;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
      Task.FromResult(new HttpResponseMessage(Code) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
  }

  public void Dispose() { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
}
