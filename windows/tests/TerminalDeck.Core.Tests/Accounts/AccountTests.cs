using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class FakeAccountProvider(string provider) : IAccountProvider
{
  public string Provider => provider;
  public Dictionary<string, ProviderAccountStatus> Statuses { get; } = [];
  public ProviderModel[] Models { get; set; } = [new("ordinary", "Ordinary", 200_000)];
  public bool ModelFailure { get; set; }
  public List<string> Calls { get; } = [];
  public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(Statuses.GetValueOrDefault(account.Id, new(false, null)));
  public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) { Calls.Add("sign-in:" + account.Id); return ValueTask.CompletedTask; }
  public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) { Statuses[account.Id] = new(false, account.Email); Calls.Add("sign-out:" + account.Id); return ValueTask.CompletedTask; }
  public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct)
  {
    if (ModelFailure) throw new IOException("Synthetic provider unavailable.");
    return ValueTask.FromResult<IReadOnlyList<ProviderModel>>(Models);
  }
}

public sealed class FakeAccountRuntime : IConversationAccountRuntime
{
  public ConversationBinding Binding { get; set; } = new("session", "stable-chat", "vendor-chat", "codex", "old", "old-home", 1);
  public List<string> Calls { get; } = [];
  public bool FailApply { get; set; }
  public bool FailRollback { get; set; }
  public bool EmptyConversation { get; set; }
  public Action? DuringApply { get; set; }
  public ValueTask<ConversationBinding> ReadAsync(string sessionId, CancellationToken ct) => ValueTask.FromResult(Binding);
  public ValueTask<AccountSwitchPlan> PrepareAsync(string id, ConversationBinding before, AccountProfile destination, CancellationToken ct)
  {
    Calls.Add("prepare");
    return ValueTask.FromResult(new AccountSwitchPlan(id, before, before with { AccountId = destination.Id, HomeId = destination.HomeId, Provider = destination.Provider, ConversationId = EmptyConversation ? "new-chat" : before.ConversationId, Revision = before.Revision + 1 }, "carryover-ref"));
  }
  public ValueTask ApplyAsync(AccountSwitchPlan plan, CancellationToken ct)
  {
    Calls.Add("apply");
    if (Binding != plan.Before && Binding != plan.After) throw new InvalidOperationException("Stale.");
    Binding = plan.After; DuringApply?.Invoke(); if (FailApply) throw new IOException("Synthetic switch failure.");
    return ValueTask.CompletedTask;
  }
  public ValueTask RollbackAsync(AccountSwitchPlan plan, CancellationToken ct)
  {
    Calls.Add("rollback"); if (FailRollback) throw new IOException("Synthetic rollback failure."); Binding = plan.Before; return ValueTask.CompletedTask;
  }
}

public sealed class AccountTests
{
  [Fact] public async Task SubscriptionRowsMergeByProviderAndNormalizedEmailWithStableAliases()
  {
    var provider = new FakeAccountProvider("codex"); var other = new FakeAccountProvider("claude"); var store = new MemoryState<AccountState>(); var service = new AccountService(store, [provider, other]);
    var a = await service.CreateAsync("codex", "Work"); var b = await service.CreateAsync("codex", "Again"); var c = await service.CreateAsync("claude", "Claude");
    provider.Statuses[a.Id] = new(true, " Person@Example.test "); provider.Statuses[b.Id] = new(true, "person@example.test"); other.Statuses[c.Id] = new(true, "person@example.test");
    await service.RefreshAsync(a.Id); await service.SetDefaultAsync("codex", b.Id); var merged = await service.RefreshAsync(b.Id); await service.RefreshAsync(c.Id);
    Assert.Equal(a.Id, merged.Id); Assert.Equal(a.Id, service.Get(b.Id).Id); Assert.Equal(a.Id, service.Default("codex")!.Id); Assert.Equal(2, service.List().Count);
    Assert.Equal(b.HomeId, merged.HomeId); Assert.Equal(2, new AccountService(store, [provider, other]).List().Count);
  }

  [Fact] public async Task ApiKeysNeverMergeEvenWithTheSameEmail()
  {
    var provider = new FakeAccountProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var a = await service.CreateAsync("codex", "Key A", AccountAuthentication.ApiKey); var b = await service.CreateAsync("codex", "Key B", AccountAuthentication.ApiKey);
    provider.Statuses[a.Id] = provider.Statuses[b.Id] = new(true, "same@example.test");
    await service.RefreshAsync(a.Id); await service.RefreshAsync(b.Id); Assert.Equal(2, service.List().Count);
  }

  [Fact] public async Task SignedOutRefusalHasAPlainSentenceAndSignInAction()
  {
    var provider = new FakeAccountProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]); var row = await service.CreateAsync("codex", "Work");
    var error = await Assert.ThrowsAsync<SignInRequiredException>(async () => await service.RequireSignedInAsync(row.Id));
    Assert.Equal("Sign in", error.ActionLabel); Assert.Contains("Work", error.Message); Assert.EndsWith(".", error.Message);
    await service.SignInAsync(row.Id, "C:\\work"); Assert.Contains("sign-in:" + row.Id, provider.Calls); Assert.False(service.Get(row.Id).SignedIn);
  }

  [Theory] [InlineData("claude")] [InlineData("codex")] [InlineData("gemini")]
  public async Task ModelListsPreserveActualProviderVariantsAndTimestampedFallback(string name)
  {
    var provider = new FakeAccountProvider(name) { Models = [new("standard", "Standard", 200_000), new("long-1m", "Long", 1_000_000, true)] };
    var service = new AccountService(new MemoryState<AccountState>(), [provider]); var row = await service.CreateAsync(name, "Work"); provider.Statuses[row.Id] = new(true, "person@example.test");
    var live = await service.ModelsAsync(row.Id); Assert.Equal(provider.Models, live.Models); Assert.False(live.Cached);
    provider.ModelFailure = true; var cached = await service.ModelsAsync(row.Id); Assert.True(cached.Cached); Assert.Equal(live.CheckedAt, cached.CheckedAt); Assert.Equal(live.Models, cached.Models);
    await service.SignOutAsync(row.Id); await Assert.ThrowsAsync<SignInRequiredException>(async () => await service.ModelsAsync(row.Id));
  }

  [Fact] public async Task UnsupportedOneMillionVariantsAreNotInvented()
  {
    var provider = new FakeAccountProvider("codex"); var service = new AccountService(new MemoryState<AccountState>(), [provider]); var row = await service.CreateAsync("codex", "Work"); provider.Statuses[row.Id] = new(true, "person@example.test");
    Assert.Single((await service.ModelsAsync(row.Id)).Models); Assert.False((await service.ModelsAsync(row.Id)).Models[0].SupportsOneMillion);
  }

  [Fact] public async Task InvalidModelEvidenceIsRefused()
  {
    var provider = new FakeAccountProvider("codex") { Models = [new("bad", "Bad", 1000, true)] }; var service = new AccountService(new MemoryState<AccountState>(), [provider]);
    var row = await service.CreateAsync("codex", "Work"); provider.Statuses[row.Id] = new(true, "person@example.test");
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.ModelsAsync(row.Id));
  }

  [Fact] public async Task FolderDefaultsRenameAndInUseDeletionStayConsistent()
  {
    var service = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]); var a = await service.CreateAsync("codex", "A"); var b = await service.CreateAsync("codex", "B");
    await service.SetDefaultAsync("codex", a.Id); await service.SetDefaultAsync("codex", b.Id, "C:\\work"); Assert.Equal(b.Id, service.Default("codex", "C:\\work")!.Id);
    await service.RenameAsync(b.Id, "Work"); await service.ShareHistoryAsync(b.Id, true); Assert.True(service.Get("Work").ShareHistory);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.DeleteAsync(b.Id, _ => true));
    await service.DeleteAsync(b.Id, _ => false); Assert.Equal(a.Id, service.Default("codex", "C:\\work")!.Id);
  }

  [Fact] public async Task FailedAccountSaveDoesNotPublishARow()
  {
    var store = new MemoryState<AccountState> { FailSave = true }; var service = new AccountService(store, [new FakeAccountProvider("codex")]);
    await Assert.ThrowsAsync<IOException>(async () => await service.CreateAsync("codex", "A")); Assert.Empty(service.List());
  }

  [Fact] public async Task SuccessfulSwitchKeepsTheExactConversationAndHome()
  {
    var (accounts, provider, destination) = await Setup(); var runtime = new FakeAccountRuntime(); var journal = new MemoryState<AccountSwitchJournal>();
    var coordinator = new AccountSwitchCoordinator(accounts, runtime, journal); var plan = await coordinator.SwitchAsync("session", destination.Id);
    Assert.Equal(plan.Before.ConversationId, runtime.Binding.ConversationId); Assert.Equal(plan.Before.ProviderConversationId, runtime.Binding.ProviderConversationId);
    Assert.Equal(destination.HomeId, runtime.Binding.HomeId); Assert.Equal(SwitchState.Committed, Assert.Single(journal.Value!.Entries).State); Assert.True(provider.Statuses[destination.Id].SignedIn);
  }

  [Fact] public async Task SignedOutSwitchDoesNothingToConversation()
  {
    var (accounts, provider, destination) = await Setup(); provider.Statuses[destination.Id] = new(false, null); var runtime = new FakeAccountRuntime(); var before = runtime.Binding;
    var coordinator = new AccountSwitchCoordinator(accounts, runtime, new MemoryState<AccountSwitchJournal>());
    await Assert.ThrowsAsync<SignInRequiredException>(async () => await coordinator.SwitchAsync("session", destination.Id)); Assert.Equal(before, runtime.Binding); Assert.Empty(runtime.Calls);
  }

  [Fact] public async Task EmptyConversationHandoverIsRefusedBeforeAnySwitch()
  {
    var (accounts, _, destination) = await Setup(); var runtime = new FakeAccountRuntime { EmptyConversation = true }; var before = runtime.Binding;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await new AccountSwitchCoordinator(accounts, runtime, new MemoryState<AccountSwitchJournal>()).SwitchAsync("session", destination.Id));
    Assert.Equal(before, runtime.Binding); Assert.DoesNotContain("apply", runtime.Calls);
  }

  [Fact] public async Task FailedApplyRollsBackTheConversation()
  {
    var (accounts, _, destination) = await Setup(); var runtime = new FakeAccountRuntime { FailApply = true }; var before = runtime.Binding; var journal = new MemoryState<AccountSwitchJournal>();
    await Assert.ThrowsAsync<IOException>(async () => await new AccountSwitchCoordinator(accounts, runtime, journal).SwitchAsync("session", destination.Id));
    Assert.Equal(before, runtime.Binding); Assert.Equal(SwitchState.RolledBack, Assert.Single(journal.Value!.Entries).State);
  }

  [Fact] public async Task SignOutDuringSwitchRollsBackAfterAwait()
  {
    var (accounts, provider, destination) = await Setup(); var runtime = new FakeAccountRuntime { DuringApply = () => provider.Statuses[destination.Id] = new(false, null) }; var before = runtime.Binding;
    await Assert.ThrowsAsync<SignInRequiredException>(async () => await new AccountSwitchCoordinator(accounts, runtime, new MemoryState<AccountSwitchJournal>()).SwitchAsync("session", destination.Id));
    Assert.Equal(before, runtime.Binding);
  }

  [Fact] public async Task CrashAfterApplyRecoversPendingIntentIdempotently()
  {
    var (accounts, _, destination) = await Setup(); var runtime = new FakeAccountRuntime(); var journal = new MemoryState<AccountSwitchJournal>(); var coordinator = new AccountSwitchCoordinator(accounts, runtime, journal);
    runtime.DuringApply = () => journal.FailSave = true;
    await Assert.ThrowsAsync<IOException>(async () => await coordinator.SwitchAsync("session", destination.Id)); Assert.Equal(destination.Id, runtime.Binding.AccountId);
    journal.FailSave = false; runtime.DuringApply = null;
    await new AccountSwitchCoordinator(accounts, runtime, journal).RecoverAsync(); Assert.Equal(destination.Id, runtime.Binding.AccountId); Assert.Equal(SwitchState.Committed, Assert.Single(journal.Value!.Entries).State);
  }

  [Fact] public async Task FailedRollbackLeavesRecoverableIntent()
  {
    var (accounts, _, destination) = await Setup(); var runtime = new FakeAccountRuntime { FailApply = true, FailRollback = true }; var journal = new MemoryState<AccountSwitchJournal>();
    await Assert.ThrowsAsync<IOException>(async () => await new AccountSwitchCoordinator(accounts, runtime, journal).SwitchAsync("session", destination.Id));
    Assert.Equal(SwitchState.Pending, Assert.Single(journal.Value!.Entries).State);
    runtime.FailApply = false; runtime.FailRollback = false; await new AccountSwitchCoordinator(accounts, runtime, journal).RecoverAsync(); Assert.Equal(SwitchState.Committed, Assert.Single(journal.Value.Entries).State);
  }

  [Fact] public async Task CredentialBytesStayInTheInjectedRootScopedStore()
  {
    var secrets = new FakeSecrets(); var a = new AccountCredentials(secrets, AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w2-vault-a"))); var b = new AccountCredentials(secrets, AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w2-vault-b")));
    var value = Encoding.UTF8.GetBytes("synthetic-test-credential"); var reference = await a.StoreAsync(value); Assert.Equal(value, await a.ReadAsync(reference)); Assert.Null(await b.ReadAsync(reference));
    Assert.DoesNotContain(Encoding.UTF8.GetString(value), JsonSerializer.Serialize(new { reference })); await a.DeleteAsync(reference); Assert.Null(await a.ReadAsync(reference));
  }

  private static async Task<(AccountService, FakeAccountProvider, AccountProfile)> Setup()
  {
    var provider = new FakeAccountProvider("codex"); var accounts = new AccountService(new MemoryState<AccountState>(), [provider]); var destination = await accounts.CreateAsync("codex", "Work");
    provider.Statuses[destination.Id] = new(true, "person@example.test"); return (accounts, provider, destination);
  }
  private sealed class FakeSecrets : ISecretStore
  {
    private readonly Dictionary<string, byte[]> values = [];
    public ValueTask<byte[]?> ReadAsync(string name, CancellationToken ct = default) => ValueTask.FromResult(values.TryGetValue(name, out var value) ? value.ToArray() : null);
    public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken ct = default) { values[name] = value.ToArray(); return ValueTask.CompletedTask; }
    public ValueTask DeleteAsync(string name, CancellationToken ct = default) { values.Remove(name); return ValueTask.CompletedTask; }
  }
}
