using System.Collections.Concurrent;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

public sealed class AccountService
{
  private readonly IStateStore<AccountState> store;
  private readonly Dictionary<string, IAccountProvider> providers;
  private readonly SemaphoreSlim gate = new(1);
  private readonly ConcurrentDictionary<string, (string Home, string? Email, ProviderModelList List)> modelCache = [];
  private readonly ConcurrentDictionary<string, Lazy<Task<ProviderModelList>>> modelReads = [];
  private readonly ConcurrentDictionary<string, int> modelVersions = [];
  private AccountState state;
  public event Action? Changed;
  public AccountService(IStateStore<AccountState> store, IEnumerable<IAccountProvider> providers)
  {
    this.store = store; this.providers = providers.ToDictionary(p => p.Provider);
    state = store.Load() ?? new(1, [], [], []);
    if (state.Version != 1 || state.Accounts.Select(a => a.Id).Distinct().Count() != state.Accounts.Length)
      throw new IOException("The saved accounts could not be read safely.");
    foreach (var provider in this.providers.Values.OfType<IAccountSignInEvents>()) provider.SignInCompleted += CompleteSignInAsync;
  }
  private async ValueTask CompleteSignInAsync(string id, CancellationToken ct)
  {
    try
    {
      // Model discovery can take tens of seconds. Refresh identity immediately;
      // fetch models only when requested so login never waits behind that probe.
      await RefreshAsync(id, ct);
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException) { }
  }
  private AccountState Current() => store is JsonStateStore<AccountState> ? store.Load() ?? new(1, [], [], []) : Volatile.Read(ref state);
  private async ValueTask<IDisposable?> EnterSharedAsync(CancellationToken ct)
  {
    if (store is not JsonStateStore<AccountState> shared) return null;
    var lease = await shared.AcquireWriteAsync(ct);
    try { state = Current(); return lease; } catch { lease.Dispose(); throw; }
  }
  public IReadOnlyList<AccountProfile> List(string? provider = null) => Current().Accounts.Where(a => provider is null || a.Provider == provider).ToArray();
  public async ValueTask EnsureDefaultAsync(string provider, bool followExisting, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      using var sharedLease = await EnterSharedAsync(ct);
      var next = state;
      var rows = state.Accounts.Where(a => a.Provider == provider).ToArray();
      var row = rows.FirstOrDefault(a => a.HomeId == AccountHomes.ExistingLogin || a.Name == "Default");
      if (row is null && rows.Length == 1 && (!followExisting || !rows[0].SignedIn && rows[0].Email is null) && (rows[0].Name is "Claude Code" or "Codex" or "Gemini"))
      {
        row = rows[0] with { Name = "Default", HomeId = followExisting ? AccountHomes.ExistingLogin : rows[0].HomeId };
        next = next with { Accounts = next.Accounts.Select(a => a.Id == row.Id ? row : a).ToArray() };
      }
      if (row is null && !followExisting)
      {
        var savedDefault = state.Defaults.FirstOrDefault(d => d.Provider == provider && d.Folder is null);
        row = rows.FirstOrDefault(a => a.Id == savedDefault?.AccountId);
      }
      if (row is null)
      {
        var id = Guid.NewGuid().ToString("N");
        row = new(id, provider, "Default", null, AccountAuthentication.Subscription, false, followExisting ? AccountHomes.ExistingLogin : id);
        next = next with { Accounts = [.. next.Accounts, row] };
      }
      var saved = next with { Defaults = next.Defaults.Any(d => d.Provider == provider && d.Folder is null) ? next.Defaults : [.. next.Defaults, new(provider, null, row.Id)] };
      if (saved != state) Save(saved);
    }
    finally { gate.Release(); }
  }
  public AccountProfile Get(string idOrName)
  {
    var current = Current();
    var id = current.Aliases.FirstOrDefault(a => a.From == idOrName)?.Into ?? idOrName;
    var rows = current.Accounts.Where(a => a.Id == id || a.Name.Equals(id, StringComparison.OrdinalIgnoreCase)).ToArray();
    return rows.Length == 1 ? rows[0] : throw new ArgumentException("Choose one account from the account list.");
  }
  // The account a start uses when none is named: the caller's own (same AI), the
  // folder's or app default, else the one the person signed in (CAPTEST: tasks and
  // tool-started chats took an unsigned placeholder account and stalled).
  public AccountProfile? Preferred(string provider, string? folder = null, string? callerAccount = null)
  {
    if (callerAccount is not null && Current().Accounts.FirstOrDefault(a => a.Id == callerAccount && a.Provider == provider) is { } own) return own;
    if (Default(provider, folder) is { } chosen) return chosen;
    var rows = List(provider);
    return rows.FirstOrDefault(a => a.SignedIn) ?? (rows.Count == 1 ? rows[0] : null);
  }
  public AccountProfile? Default(string provider, string? folder = null)
  {
    var rows = Current().Defaults.Where(d => d.Provider == provider).ToArray();
    var choice = rows.FirstOrDefault(d => folder is not null && d.Folder == folder) ?? rows.FirstOrDefault(d => d.Folder is null);
    return choice is null ? null : Get(choice.AccountId);
  }

  public async ValueTask<AccountProfile> CreateAsync(string provider, string name, AccountAuthentication authentication = AccountAuthentication.Subscription,
    string? credentialReference = null, CancellationToken cancellationToken = default)
  {
    if (!providers.ContainsKey(provider) || string.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Any(char.IsControl) || !Enum.IsDefined(authentication))
      throw new ArgumentException("Choose a provider and an account name.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      using var sharedLease = await EnterSharedAsync(cancellationToken);
      var id = Guid.NewGuid().ToString("N");
      var used = state.Accounts.Where(a => a.Provider == provider).Select(a => a.Color).ToHashSet();
      var color = AccountColors.All.FirstOrDefault(c => !used.Contains(c)) ?? AccountColors.All[state.Accounts.Length % AccountColors.All.Length];
      var row = new AccountProfile(id, provider, name.Trim(), null, authentication, false, id, credentialReference, Color: color);
      Save(state with { Accounts = [.. state.Accounts, row] });
      return row;
    }
    finally { gate.Release(); }
  }

  public async ValueTask<AccountProfile> RefreshAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      using var sharedLease = await EnterSharedAsync(cancellationToken);
      var row = Get(id);
      // An API-key account has no CLI login to read; its state is its saved key.
      if (row.Authentication == AccountAuthentication.ApiKey) return row;
      var status = await providers[row.Provider].StatusAsync(row, cancellationToken);
      if (status.SignedIn && row.Authentication == AccountAuthentication.Subscription && string.IsNullOrWhiteSpace(status.Email))
        throw new InvalidOperationException("The provider has not confirmed this account's email yet.");
      var email = status.Email?.Trim().ToLowerInvariant();
      var existing = row.Authentication == AccountAuthentication.Subscription && status.SignedIn
        ? state.Accounts.FirstOrDefault(a => a.Id != row.Id && a.Provider == row.Provider && a.Authentication == AccountAuthentication.Subscription && a.Email == email && a.HomeId != AccountHomes.ExistingLogin && row.HomeId != AccountHomes.ExistingLogin)
        : null;
      if (existing is not null)
      {
        // Keep the stable row id; the newly verified home owns the current login.
        var merged = existing with { SignedIn = true, HomeId = row.HomeId, CredentialReference = row.CredentialReference };
        Save(state with
        {
          Accounts = state.Accounts.Where(a => a.Id != row.Id).Select(a => a.Id == existing.Id ? merged : a).ToArray(),
          Aliases = state.Aliases.Select(a => a.Into == row.Id ? a with { Into = existing.Id } : a).Append(new(row.Id, existing.Id)).ToArray(),
          Defaults = state.Defaults.Select(d => d.AccountId == row.Id ? d with { AccountId = existing.Id } : d).ToArray()
        });
        InvalidateModels(row.Id); InvalidateModels(existing.Id);
        return merged;
      }
      var next = row with { SignedIn = status.SignedIn, Email = status.SignedIn ? email : row.Email, Plan = status.SignedIn ? status.Plan ?? row.Plan : row.Plan };
      Replace(next);
      if (!next.SignedIn || row.Email != next.Email) InvalidateModels(row.Id);
      return next;
    }
    finally { gate.Release(); }
  }

  public ValueTask<ProviderInstallation> InstallationAsync(string id, CancellationToken ct = default)
  {
    var row = Get(id);
    return providers[row.Provider] is IAccountInstallation installation ? installation.InstallationAsync(row, ct)
      : ValueTask.FromResult(new ProviderInstallation(null, null, DateTimeOffset.UtcNow, "Installation status is unavailable for this provider."));
  }

  public async ValueTask<AccountProfile> RequireSignedInAsync(string id, CancellationToken cancellationToken = default)
  {
    var row = await RefreshAsync(id, cancellationToken);
    if (!row.SignedIn) throw new SignInRequiredException(row);
    return row;
  }

  public async ValueTask SignInAsync(string id, string folder, CancellationToken cancellationToken = default)
  {
    if (string.IsNullOrWhiteSpace(folder) || folder.Contains('\0')) throw new ArgumentException("Choose a folder for sign-in.");
    var row = Get(id);
    if (row.Authentication == AccountAuthentication.ApiKey) throw new InvalidOperationException("This account uses an API key. Choose Edit API key to change it.");
    await gate.WaitAsync(cancellationToken);
    try { InvalidateModels(row.Id); }
    finally { gate.Release(); }
    await providers[row.Provider].SignInAsync(row, folder, cancellationToken);
  }
  public async ValueTask SignOutAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      using var sharedLease = await EnterSharedAsync(cancellationToken);
      var row = Get(id);
      if (row.Authentication == AccountAuthentication.ApiKey) throw new InvalidOperationException("This account uses an API key. Remove it, or edit its key.");
      await providers[row.Provider].SignOutAsync(row, cancellationToken);
      Replace(row with { SignedIn = false }); InvalidateModels(row.Id);
    }
    finally { gate.Release(); }
  }
  public async ValueTask RenameAsync(string id, string name, CancellationToken cancellationToken = default)
  {
    if (string.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Any(char.IsControl)) throw new ArgumentException("Choose a short account name.");
    await gate.WaitAsync(cancellationToken);
    try { using var sharedLease = await EnterSharedAsync(cancellationToken); Replace(Get(id) with { Name = name.Trim() }); }
    finally { gate.Release(); }
  }
  public async ValueTask SetColorAsync(string id, string color, CancellationToken cancellationToken = default)
  {
    if (!AccountColors.All.Contains(color)) throw new ArgumentException("Choose one of the account colours.");
    await gate.WaitAsync(cancellationToken);
    try { using var sharedLease = await EnterSharedAsync(cancellationToken); Replace(Get(id) with { Color = color }); }
    finally { gate.Release(); }
  }
  // API-key accounts: their saved key decides whether they are ready.
  public async ValueTask<AccountProfile> SetApiStateAsync(string id, bool configured, string? credentialReference, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      using var sharedLease = await EnterSharedAsync(cancellationToken);
      var row = Get(id);
      if (row.Authentication != AccountAuthentication.ApiKey) throw new ArgumentException("Choose an API-key account.");
      var next = row with { SignedIn = configured, CredentialReference = credentialReference };
      Replace(next); InvalidateModels(row.Id); return next;
    }
    finally { gate.Release(); }
  }
  public async ValueTask ShareHistoryAsync(string id, bool share, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { using var sharedLease = await EnterSharedAsync(cancellationToken); Replace(Get(id) with { ShareHistory = share }); }
    finally { gate.Release(); }
  }
  public async ValueTask SetDefaultAsync(string provider, string? accountId, string? folder = null, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      using var sharedLease = await EnterSharedAsync(cancellationToken);
      var row = accountId is null ? null : Get(accountId);
      if (row is not null && row.Provider != provider) throw new ArgumentException("Choose an account for this provider.");
      var defaults = state.Defaults.Where(d => !(d.Provider == provider && d.Folder == folder));
      Save(state with { Defaults = row is null ? defaults.ToArray() : defaults.Append(new(provider, folder, row.Id)).ToArray() });
    }
    finally { gate.Release(); }
  }
  public async ValueTask DeleteAsync(string id, Func<string, bool> inUse, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      using var sharedLease = await EnterSharedAsync(cancellationToken);
      var row = Get(id);
      if (inUse(row.Id)) throw new InvalidOperationException("This account is still used by a session. Switch that session first.");
      Save(state with { Accounts = state.Accounts.Where(a => a.Id != row.Id).ToArray(), Aliases = state.Aliases.Where(a => a.Into != row.Id).ToArray(), Defaults = state.Defaults.Where(d => d.AccountId != row.Id).ToArray() });
      InvalidateModels(row.Id);
    }
    finally { gate.Release(); }
  }
  private void InvalidateModels(string id)
  {
    modelCache.TryRemove(id, out _);
    modelVersions.AddOrUpdate(id, 1, (_, version) => version + 1);
  }
  // What a picker shows the moment it opens: the last live list for this account,
  // else the AI's preloaded list. ModelsAsync then brings the live one.
  public ProviderModelList InstantModels(string provider, string? accountId)
  {
    if (accountId is { Length: > 0 } && CachedModels(accountId) is { } held) return held;
    return new(ModelCatalog.For(provider).ToArray(), DateTimeOffset.UtcNow, Cached: true);
  }
  public ProviderModelList? CachedModels(string id)
  {
    AccountProfile row;
    try { row = Get(id); } catch (ArgumentException) { return null; }
    return row.SignedIn && modelCache.TryGetValue(row.Id, out var held) && held.Home == row.HomeId && held.Email == row.Email
      ? held.List with { Models = [.. held.List.Models], Cached = true } : null;
  }
  // Every consumer shares a catalogue by AI/account/home; opening a picker does
  // not authenticate or launch another CLI. A failed refresh keeps the last list.
  public async ValueTask<ProviderModelList> ModelsAsync(string id, bool allowCached = true, CancellationToken cancellationToken = default)
  {
    var row = Get(id);
    if (allowCached && CachedModels(row.Id) is { } cached)
    {
      if (DateTimeOffset.UtcNow - cached.CheckedAt > TimeSpan.FromMinutes(1)) _ = RefreshModelsQuietlyAsync(row.Id);
      return cached;
    }
    var version = modelVersions.GetValueOrDefault(row.Id);
    var key = $"{row.Provider}:{row.Id}:{row.HomeId}:{row.Email}:{version}";
    var lazy = modelReads.GetOrAdd(key, _ => new(() => ReadModelsAsync(row.Id), LazyThreadSafetyMode.ExecutionAndPublication));
    try { return await lazy.Value.WaitAsync(cancellationToken); }
    finally { if (lazy.IsValueCreated && lazy.Value.IsCompleted) modelReads.TryRemove(new KeyValuePair<string, Lazy<Task<ProviderModelList>>>(key, lazy)); }
  }
  private async Task<ProviderModelList> ReadModelsAsync(string id)
  {
    var row = await RequireSignedInAsync(id);
    var version = modelVersions.GetValueOrDefault(row.Id);
    // API accounts are not asked through a CLI login; they offer the AI's known models.
    var models = row.Authentication == AccountAuthentication.ApiKey ? ModelCatalog.For(row.Provider).ToArray()
      : (await providers[row.Provider].ModelsAsync(row, CancellationToken.None)).ToArray();
    if (models.Length == 0 || models.Any(m => string.IsNullOrWhiteSpace(m.Id) || m.ContextTokens < 0 || m.SupportsOneMillion && m.ContextTokens < 1_000_000) || models.Select(m => m.Id).Distinct().Count() != models.Length)
      throw new InvalidOperationException("The provider returned an unusable model list.");
    var result = new ProviderModelList(models, DateTimeOffset.UtcNow);
    var current = Get(row.Id);
    if (current.SignedIn && current.HomeId == row.HomeId && current.Email == row.Email && modelVersions.GetValueOrDefault(row.Id) == version)
      modelCache[row.Id] = (row.HomeId, row.Email, result);
    return result with { Models = [.. models] };
  }
  private async Task RefreshModelsQuietlyAsync(string id)
  {
    try { await ModelsAsync(id, allowCached: false); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException) { }
  }
  public async Task WarmModelsAsync(CancellationToken cancellationToken = default)
  {
    await Task.WhenAll(List().Where(a => a.SignedIn).Select(a => RefreshModelsQuietlyAsync(a.Id))).WaitAsync(cancellationToken);
  }
  private void Replace(AccountProfile row)
  {
    if (state.Accounts.Any(a => a == row)) return;
    Save(state with { Accounts = state.Accounts.Select(a => a.Id == row.Id ? row : a).ToArray() });
  }
  private void NotifyChanged() => Changed?.Invoke();
  private void Save(AccountState next) { store.Save(next); Volatile.Write(ref state, next); NotifyChanged(); }
}
