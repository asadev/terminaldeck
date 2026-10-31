using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class ModelCatalogueCacheTests
{
  private sealed class CatalogueProvider(string name) : IAccountProvider
  {
    public string Provider => name;
    public int Reads;
    public int StatusReads;
    public TaskCompletionSource<IReadOnlyList<ProviderModel>>? Pending;
    public bool Fail;
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct)
    { StatusReads++; return ValueTask.FromResult(new ProviderAccountStatus(true, account.Id + "@example.test")); }
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct)
    {
      Reads++;
      if (Fail) throw new IOException("Fixture offline");
      return Pending is { } pending ? new(pending.Task) : ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new(account.Id, "Model for " + account.Id, 0)]);
    }
  }
  [Fact]
  public async Task WarmupMakesPickerReadSynchronousWithoutAuthenticationOrCliCall()
  {
    var provider = new CatalogueProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var account = await service.CreateAsync("codex", "Work"); await service.RefreshAsync(account.Id);
    await service.WarmModelsAsync(); var reads = provider.Reads; var statusReads = provider.StatusReads;
    var opening = service.ModelsAsync(account.Id);
    Assert.True(opening.IsCompletedSuccessfully); Assert.True((await opening).Cached);
    Assert.Equal(reads, provider.Reads); Assert.Equal(statusReads, provider.StatusReads);
    var rows = (await opening).Models; rows[0] = new("tampered", "Tampered", 0);
    Assert.Equal(account.Id, service.CachedModels(account.Id)!.Models[0].Id);
  }
  [Fact]
  public async Task ConcurrentColdReadsShareProbeAndWarmPickerDoesNotWaitForRefresh()
  {
    var provider = new CatalogueProvider("claude"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var account = await service.CreateAsync("claude", "Work"); await service.RefreshAsync(account.Id);
    await service.ModelsAsync(account.Id);
    provider.Pending = new(TaskCreationOptions.RunContinuationsAsynchronously);
    var refreshing = service.ModelsAsync(account.Id, allowCached: false).AsTask();
    var secondRefresh = service.ModelsAsync(account.Id, allowCached: false).AsTask();
    var opening = service.ModelsAsync(account.Id);
    Assert.True(opening.IsCompletedSuccessfully); Assert.False(refreshing.IsCompleted); Assert.Equal(2, provider.Reads);
    Assert.Equal(account.Id, (await opening).Models[0].Id);
    provider.Pending.SetResult([new("new-model", "New model", 0)]);
    await Task.WhenAll(refreshing, secondRefresh);
    Assert.Equal("new-model", service.CachedModels(account.Id)!.Models[0].Id);
  }
  [Fact]
  public async Task FailedRefreshKeepsModelsAndAccountsNeverShareRows()
  {
    var provider = new CatalogueProvider("gemini"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var one = await service.CreateAsync("gemini", "One"); var two = await service.CreateAsync("gemini", "Two");
    await service.ModelsAsync(one.Id); await service.ModelsAsync(two.Id); provider.Fail = true;
    await Assert.ThrowsAsync<IOException>(async () => await service.ModelsAsync(one.Id, allowCached: false));
    Assert.Equal(one.Id, (await service.ModelsAsync(one.Id)).Models[0].Id);
    Assert.Equal(two.Id, (await service.ModelsAsync(two.Id)).Models[0].Id);
    await service.SignInAsync(one.Id, Path.GetTempPath()); Assert.Null(service.CachedModels(one.Id));
    Assert.NotNull(service.CachedModels(two.Id));
  }
  [Fact]
  public async Task SignOutDuringProbeCannotRepopulateAccountCache()
  {
    var provider = new CatalogueProvider("codex") { Pending = new(TaskCreationOptions.RunContinuationsAsynchronously) };
    var service = new AccountService(new MemoryState<AccountState>(), [provider]); var account = await service.CreateAsync("codex", "Work");
    var loading = service.ModelsAsync(account.Id).AsTask(); await service.SignOutAsync(account.Id);
    provider.Pending.SetResult([new("offered", "Offered", 0)]); await loading;
    Assert.Null(service.CachedModels(account.Id));
  }
}
