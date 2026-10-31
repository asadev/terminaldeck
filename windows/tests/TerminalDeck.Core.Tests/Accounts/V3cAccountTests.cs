using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class V3cAccountTests
{
  [Fact]
  public async Task ModelFallbackCannotCrossAccountsOrReplacementHomes()
  {
    var provider = new FakeAccountProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var first = await service.CreateAsync("codex", "First"); var second = await service.CreateAsync("codex", "Second");
    provider.Statuses[first.Id] = new(true, "first@example.test"); provider.Statuses[second.Id] = new(true, "second@example.test");
    await service.ModelsAsync(first.Id); provider.ModelFailure = true;
    await Assert.ThrowsAsync<IOException>(async () => await service.ModelsAsync(second.Id));
    provider.Statuses[second.Id] = new(true, "first@example.test"); await service.RefreshAsync(second.Id);
    Assert.Equal(second.HomeId, service.Get(first.Id).HomeId);
    await Assert.ThrowsAsync<IOException>(async () => await service.ModelsAsync(first.Id));
  }
  [Fact]
  public async Task StartingSignInInvalidatesThePreviousModelList()
  {
    var provider = new FakeAccountProvider("claude"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var account = await service.CreateAsync("claude", "Work"); provider.Statuses[account.Id] = new(true, "first@example.test");
    await service.ModelsAsync(account.Id); await service.SignInAsync(account.Id, Path.GetTempPath()); provider.ModelFailure = true;
    await Assert.ThrowsAsync<IOException>(async () => await service.ModelsAsync(account.Id));
  }
  [Fact]
  public async Task UnknownCapacityIsPreservedWithoutInventingOneMillionAccess()
  {
    var provider = new FakeAccountProvider("gemini") { Models = [new("reported-model", "Reported model", 0)] };
    var service = new AccountService(new MemoryState<AccountState>(), [provider]); var account = await service.CreateAsync("gemini", "Work");
    provider.Statuses[account.Id] = new(true, "person@example.test");
    var model = Assert.Single((await service.ModelsAsync(account.Id)).Models); Assert.Equal(0, model.ContextTokens); Assert.False(model.SupportsOneMillion);
  }
  [Fact]
  public async Task EmptyLiveCatalogueDoesNotReplaceUsableModels()
  {
    var provider = new FakeAccountProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]); var account = await service.CreateAsync("codex", "Work");
    provider.Statuses[account.Id] = new(true, "person@example.test"); await service.ModelsAsync(account.Id); provider.Models = [];
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.ModelsAsync(account.Id, allowCached: false));
    Assert.NotNull(service.CachedModels(account.Id));
  }
  [Fact]
  public void ReadinessListsTwelveUnverifiedChecksAndNeverClaimsALivePass()
  {
    var report = SignInReadiness.Read([]); Assert.Equal(3, report.Providers.Length);
    Assert.Equal(12, report.Providers.Sum(p => p.Checks.Length));
    Assert.All(report.Providers.SelectMany(p => p.Checks), check => Assert.StartsWith("Waiting", check.State));
    Assert.All(report.Providers, provider => Assert.Equal(new[] { "reply", "models", "switch", "approval" }, provider.Checks.Select(c => c.Id)));
  }
  [Fact]
  public void SignInDoesNotCountAsReplySwitchOrApprovalEvidence()
  {
    var report = SignInReadiness.Read([new("a", "codex", "Work", "person@example.test", AccountAuthentication.Subscription, true, "home")]);
    var codex = report.Providers.Single(p => p.Provider == "codex"); Assert.Equal(1, codex.SignedIn);
    Assert.All(codex.Checks, check => Assert.StartsWith("Waiting", check.State));
    Assert.Contains(codex.Checks, c => c.Id == "switch" && c.State.Contains("two"));
  }
  [Fact]
  public async Task SignInCompletionRefreshesIdentityImmediatelyAndReadsModelsOnDemand()
  {
    var provider = new CompletingProvider(); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var account = await service.CreateAsync("claude", "Work"); var changed = 0; service.Changed += () => changed++;
    await provider.CompleteAsync(account.Id); Assert.True(service.Get(account.Id).SignedIn); Assert.Equal(0, provider.ModelReads); Assert.Equal(1, changed);
    await service.ModelsAsync(account.Id); Assert.Equal(1, provider.ModelReads);
  }
  private sealed class CompletingProvider : IAccountProvider, IAccountSignInEvents
  {
    public string Provider => "claude";
    public int ModelReads;
    public event Func<string, CancellationToken, ValueTask>? SignInCompleted;
    public async Task CompleteAsync(string id) { if (SignInCompleted is { } handler) await handler(id, CancellationToken.None); }
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "person@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) { ModelReads++; return ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new("sonnet[1m]", "Sonnet 1M", 1_000_000, true)]); }
  }
}
