using System.Text.Json;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class FakeBrowserStorage : IBrowserProfileStorage
{
  public HashSet<string> PrivateStores { get; } = [];
  public List<string> DeletedProfiles { get; } = [];
  public List<string> DeletedPrivate { get; } = [];
  public bool FailDelete { get; set; }
  public ValueTask EnsureProfileAsync(string id, CancellationToken ct) => ValueTask.CompletedTask;
  public ValueTask CreatePrivateAsync(string id, CancellationToken ct) { Assert.True(PrivateStores.Add(id)); return ValueTask.CompletedTask; }
  public ValueTask DeletePrivateAsync(string id, CancellationToken ct) { if (FailDelete) throw new IOException("Synthetic cleanup failure."); PrivateStores.Remove(id); DeletedPrivate.Add(id); return ValueTask.CompletedTask; }
  public ValueTask DeleteProfileAsync(string id, CancellationToken ct) { if (FailDelete) throw new IOException("Synthetic cleanup failure."); DeletedProfiles.Add(id); return ValueTask.CompletedTask; }
}
public sealed class FakeBrowserFactory : IBrowserSurfaceFactory
{
  public List<(BrowserSurfaceOptions Options, FakeBrowserPage Page)> Created { get; } = [];
  public bool FailCreate { get; set; }
  public ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken ct)
  {
    if (FailCreate) throw new IOException("Synthetic page failure.");
    var page = new FakeBrowserPage(options.TabId); Created.Add((options, page)); return ValueTask.FromResult<IBrowserPage>(page);
  }
}
public sealed class FakeBrowserPage(string tabId) : IBrowserPage
{
  public string TabId => tabId;
  public int Navigations { get; private set; }
  public int Reloads { get; private set; }
  public bool BypassCache { get; private set; }
  public bool Disposed { get; private set; }
  public List<BrowserPageAction> Actions { get; } = [];
  public Task NavigateAsync(Uri address, CancellationToken ct = default) { Navigations++; return Task.CompletedTask; }
  public Task<JsonElement> DevToolsAsync(string method, JsonElement arguments, CancellationToken ct = default) => throw new InvalidOperationException("No general DevTools tool bridge.");
  public ValueTask ReloadAsync(bool bypassCache, CancellationToken ct) { Reloads++; BypassCache = bypassCache; return ValueTask.CompletedTask; }
  public ValueTask<JsonElement> PerformAsync(BrowserPageAction action, JsonElement arguments, CancellationToken ct) { Actions.Add(action); return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { done = true })); }
  public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
}

public sealed class BrowserTests
{
  [Fact] public async Task SelectionReorderingBindingAndProfileChangesKeepPagesAliveWithoutReload()
  {
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var first = await browser.OpenAsync("https://example.test/a"); var second = await browser.OpenAsync("https://example.test/b"); var profile = await browser.CreateProfileAsync("Work");
    await browser.SelectAsync(first.Id); await browser.MoveAsync(first.Id, 1); await browser.AttachAsync(first.Id, "session"); await browser.AttachAsync(first.Id, null);
    await browser.ActivateProfileAsync(profile.Id); await browser.UpdateProfileAsync(profile.Id, name: "Renamed", avatar: "🙂");
    Assert.Equal(2, factory.Created.Count); Assert.All(factory.Created, p => { Assert.Equal(1, p.Page.Navigations); Assert.Equal(0, p.Page.Reloads); Assert.False(p.Page.Disposed); });
    Assert.Equal(BrowserModel.DefaultProfileId, browser.Get(second.Id).ProfileId);
  }
  [Fact] public async Task OnlyExplicitReloadReachesReloadAndMetadataCallbacksDoNotNavigate()
  {
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage()); var tab = await browser.OpenAsync("https://example.test/a");
    await browser.ObserveNavigationAsync(tab.Id, "https://example.test/b", "A title"); Assert.Equal(1, factory.Created[0].Page.Navigations);
    await browser.ReloadAsync(tab.Id, true); Assert.Equal(1, factory.Created[0].Page.Reloads); Assert.True(factory.Created[0].Page.BypassCache);
    await browser.NavigateAsync(tab.Id, "https://example.test/c"); Assert.Equal(2, factory.Created[0].Page.Navigations); Assert.Equal(1, factory.Created[0].Page.Reloads);
  }
  [Fact] public async Task ClosingSelectsTheRightNeighborThenLeftWithoutReloadingIt()
  {
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var a = await browser.OpenAsync("https://example.test/a"); var b = await browser.OpenAsync("https://example.test/b"); var c = await browser.OpenAsync("https://example.test/c");
    await browser.SelectAsync(b.Id); await browser.CloseAsync(b.Id); Assert.Equal(c.Id, browser.Read().SelectedTabId); Assert.True(factory.Created[1].Page.Disposed);
    await browser.CloseAsync(c.Id); Assert.Equal(a.Id, browser.Read().SelectedTabId); Assert.Equal(1, factory.Created[0].Page.Navigations);
  }
  [Fact] public async Task BindingHasOneHolderAndStableNonReusedSessionSlots()
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    var first = await browser.OpenAsync("about:blank", sessionId: "s"); var second = await browser.OpenAsync("about:blank", sessionId: "s");
    Assert.Equal("B1", first.SessionSlot); Assert.Equal("B2", second.SessionSlot); await browser.CloseAsync(first.Id);
    var third = await browser.OpenAsync("about:blank", sessionId: "s"); Assert.Equal("B3", third.SessionSlot);
    await browser.AttachAsync(second.Id, "other"); Assert.Equal("other", browser.Get(second.Id).SessionId); Assert.Equal("B1", browser.Get(second.Id).SessionSlot); Assert.Equal("B3", browser.Get(third.Id).SessionSlot);
  }
  [Fact] public async Task RestoreKeepsOrderSelectionProfilesAndBindingsAndDoesNotRemountTwice()
  {
    var state = new MemoryState<BrowserState>(); var factory = new FakeBrowserFactory(); var browser = new BrowserModel(state, factory, new FakeBrowserStorage());
    var profile = await browser.CreateProfileAsync("Work"); await browser.ActivateProfileAsync(profile.Id); var a = await browser.OpenAsync("https://example.test/a", sessionId: "session"); var b = await browser.OpenAsync("https://example.test/b"); await browser.MoveAsync(b.Id, 0); await browser.SelectAsync(a.Id); await browser.DisposeAsync();
    var nextFactory = new FakeBrowserFactory(); await using var restarted = new BrowserModel(state, nextFactory, new FakeBrowserStorage()); await restarted.RestoreAsync(); await restarted.RestoreAsync();
    Assert.Equal(new[] { b.Id, a.Id }, restarted.Read().Tabs.Select(t => t.Id)); Assert.Equal(a.Id, restarted.Read().SelectedTabId); Assert.Equal(profile.Id, restarted.Read().ActiveProfileId); Assert.Equal("B1", restarted.Get(a.Id).SessionSlot);
    Assert.Equal(2, nextFactory.Created.Count); Assert.All(nextFactory.Created, p => Assert.Equal(1, p.Page.Navigations));
  }
  [Fact] public async Task PrivateTabsAlwaysUseDistinctStoresAndCloseDiscardsThem()
  {
    var storage = new FakeBrowserStorage(); var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, storage);
    var a = await browser.OpenAsync("https://example.test", true); await browser.OpenAsync("https://example.test", true); await browser.OpenAsync("https://example.test");
    Assert.Equal(2, storage.PrivateStores.Count); Assert.NotEqual(factory.Created[0].Options.PrivateStoreId, factory.Created[1].Options.PrivateStoreId); Assert.Null(factory.Created[2].Options.PrivateStoreId);
    var id = factory.Created[0].Options.PrivateStoreId!; await browser.CloseAsync(a.Id); Assert.DoesNotContain(id, storage.PrivateStores); Assert.Contains(id, storage.DeletedPrivate);
  }
  [Fact] public async Task CrashRecoveryDiscardsTheOldPrivateStoreBeforeCreatingAFreshOne()
  {
    var state = new MemoryState<BrowserState>(); var storage = new FakeBrowserStorage(); var factory = new FakeBrowserFactory();
    // Simulate a dead process by retaining only its saved metadata, without orderly Dispose.
    var first = new BrowserModel(state, factory, storage); var tab = await first.OpenAsync("https://example.test", true); var oldId = factory.Created[0].Options.PrivateStoreId!;
    var nextFactory = new FakeBrowserFactory(); await using var restarted = new BrowserModel(state, nextFactory, storage); await restarted.RestoreAsync();
    Assert.Contains(oldId, storage.DeletedPrivate); Assert.DoesNotContain(oldId, storage.PrivateStores); Assert.NotEqual(oldId, nextFactory.Created[0].Options.PrivateStoreId); Assert.True(restarted.Get(tab.Id).Isolated);
  }
  [Fact] public async Task FailedPrivateCleanupRemainsDurableAndCanBeRetried()
  {
    var state = new MemoryState<BrowserState>(); var storage = new FakeBrowserStorage(); var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(state, factory, storage);
    var tab = await browser.OpenAsync("about:blank", true); storage.FailDelete = true;
    await Assert.ThrowsAsync<IOException>(async () => await browser.CloseAsync(tab.Id)); Assert.Single(state.Value!.PrivateStoresToClean); Assert.Empty(browser.Read().Tabs);
    storage.FailDelete = false; await browser.RetryCleanupAsync(); Assert.Empty(state.Value.PrivateStoresToClean); Assert.Empty(storage.PrivateStores);
  }
  [Fact] public async Task FailedPrivateCreationRemovesPhantomTabAndKeepsCleanupEvidence()
  {
    var state = new MemoryState<BrowserState>(); var storage = new FakeBrowserStorage(); var factory = new FakeBrowserFactory { FailCreate = true }; await using var browser = new BrowserModel(state, factory, storage);
    await Assert.ThrowsAsync<IOException>(async () => await browser.OpenAsync("about:blank", true)); Assert.Empty(state.Value!.Tabs); Assert.Null(state.Value.SelectedTabId);
    var abandoned = Assert.Single(state.Value.PrivateStoresToClean); Assert.Contains(abandoned, storage.PrivateStores);
    factory.FailCreate = false; await browser.RestoreAsync();
    Assert.Empty(storage.PrivateStores); Assert.Empty(state.Value.PrivateStoresToClean); Assert.Contains(abandoned, storage.DeletedPrivate); Assert.Empty(factory.Created); Assert.Empty(browser.Read().Tabs);
    await browser.OpenAsync("about:blank", true); Assert.Single(browser.Read().Tabs); Assert.Single(storage.PrivateStores); Assert.NotEqual(abandoned, Assert.Single(factory.Created).Options.PrivateStoreId);
  }
  [Fact] public async Task ShutdownKeepsTabMetadataButDisposesPagesAndPrivateData()
  {
    var state = new MemoryState<BrowserState>(); var storage = new FakeBrowserStorage(); var factory = new FakeBrowserFactory(); var browser = new BrowserModel(state, factory, storage); await browser.OpenAsync("about:blank", true); await browser.OpenAsync("about:blank"); await browser.DisposeAsync();
    Assert.Equal(2, state.Value!.Tabs.Length); Assert.All(factory.Created, p => Assert.True(p.Page.Disposed)); Assert.Empty(storage.PrivateStores); Assert.Empty(state.Value.PrivateStoresToClean);
    await Assert.ThrowsAsync<ObjectDisposedException>(async () => await browser.SelectAsync(state.Value.Tabs[0].Id));
  }
  [Fact] public async Task DeletingProfilesProtectsDefaultAndOpenPagesAndRecoversFailedCleanup()
  {
    var state = new MemoryState<BrowserState>(); var storage = new FakeBrowserStorage(); await using var browser = new BrowserModel(state, new FakeBrowserFactory(), storage);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.DeleteProfileAsync(BrowserModel.DefaultProfileId));
    var profile = await browser.CreateProfileAsync("Work"); await browser.ActivateProfileAsync(profile.Id); var tab = await browser.OpenAsync("about:blank");
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.DeleteProfileAsync(profile.Id)); await browser.CloseAsync(tab.Id);
    storage.FailDelete = true; await Assert.ThrowsAsync<IOException>(async () => await browser.DeleteProfileAsync(profile.Id)); Assert.Contains(profile.Id, state.Value!.ProfilesToDelete);
    storage.FailDelete = false; await browser.RetryCleanupAsync(); Assert.DoesNotContain(browser.Read().Profiles, p => p.Id == profile.Id); Assert.Equal(BrowserModel.DefaultProfileId, browser.Read().ActiveProfileId);
  }
  [Theory] [InlineData("javascript:alert(1)")] [InlineData("file:///C:/private")] [InlineData("https://user:pass@example.test")]
  public void UnsafeSchemesAndEmbeddedCredentialsAreRefused(string address) => Assert.Throws<ArgumentException>(() => BrowserModel.Address(address));
  [Fact] public async Task FailedMetadataSaveNeverCreatesASurfaceOrPrivateStore()
  {
    var storage = new FakeBrowserStorage(); var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState> { FailSave = true }, factory, storage);
    await Assert.ThrowsAsync<IOException>(async () => await browser.OpenAsync("about:blank", true)); Assert.Empty(factory.Created); Assert.Empty(storage.PrivateStores);
  }
  [Fact] public async Task BrowserChangeStreamReportsTheLatestStateWithoutPolling()
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage()); var tab = await browser.OpenAsync("about:blank"); await browser.AttachAsync(tab.Id, "session");
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(2)); await using var changes = browser.Changes(ct.Token).GetAsyncEnumerator(); Assert.True(await changes.MoveNextAsync()); Assert.Equal("session", Assert.Single(changes.Current.Tabs).SessionId);
  }
  [Fact] public async Task SnapshotArraysCannotMutateTheLiveModel()
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage()); await browser.OpenAsync("about:blank"); var snapshot = browser.Read(); snapshot.Tabs[0] = snapshot.Tabs[0] with { Url = "https://example.test/changed" };
    Assert.Equal("about:blank", browser.Read().Tabs[0].Url);
  }
  [Fact] public async Task BrowserToolsReachTheSameModelAndApplyDynamicApproval()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper());
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage()); BrowserTools.Register(door, browser, keeper);
    var registration = door.RegisterCaller(McpTests.Grant("browser.open", "browser.close", "browser.windows", "browser.page", "browser.profiles") with { OwnerApplication = true, SessionId = null }, (g, t, a, tier, ct) => ValueTask.FromResult(true));
    await door.CallAsync(registration.Id, "browser.open", JsonSerializer.SerializeToElement(new { url = "https://example.test" })); Assert.Single(browser.Read().Tabs);
    var id = browser.Read().Tabs[0].Id; var before = permission.Requests.Count;
    await door.CallAsync(registration.Id, "browser.page", JsonSerializer.SerializeToElement(new { action = "state", window = id })); Assert.Equal(before, permission.Requests.Count);
    await door.CallAsync(registration.Id, "browser.page", JsonSerializer.SerializeToElement(new { action = "reload", window = id })); Assert.Equal(1, factory.Created[0].Page.Reloads);
    await door.CallAsync(registration.Id, "browser.profiles", JsonSerializer.SerializeToElement(new { action = "create", name = "Work" })); Assert.Equal(McpTier.Alter, permission.Requests[^1].Tier); Assert.Equal(2, browser.Read().Profiles.Length);
    Assert.DoesNotContain(door.List(registration.Id), t => t.Id == "browser.step");
    await door.CallAsync(registration.Id, "browser.close", JsonSerializer.SerializeToElement(new { window = id })); Assert.Empty(browser.Read().Tabs);
  }
  [Fact] public async Task BrowserBindingToolIsAnAlterAndKeepsThePage()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper()); var session = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "C:\\work", "A"));
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage()); var tab = await browser.OpenAsync("about:blank"); BrowserTools.Register(door, browser, keeper);
    var caller = door.RegisterCaller(McpTests.Grant("browser.windows") with { OwnerApplication = true, SessionId = null }, (g, t, a, tier, ct) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "browser.windows", JsonSerializer.SerializeToElement(new { action = "attach", window = tab.Id, sessionId = session.Definition.Id }));
    Assert.Equal(McpTier.Alter, Assert.Single(permission.Requests).Tier); Assert.Equal(session.Definition.Id, browser.Get(tab.Id).SessionId); Assert.Equal(1, factory.Created[0].Page.Navigations);
  }
  [Fact] public async Task OrdinarySessionCannotReadBrowserSettingsEvenWithBroadResourceGrants()
  {
    var door = new McpDoor(new FakePermission()); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage()); BrowserTools.Register(door, browser, new(new MemoryState<SessionLedger>(), new FakeProcessKeeper()));
    var caller = door.RegisterCaller(McpTests.Grant("browser.profiles"), (g, t, a, tier, ct) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "browser.profiles", JsonSerializer.SerializeToElement(new { action = "list" })));
  }
  [Fact] public async Task MissingOriginGrantRefusesNavigationBeforeTouchingThePage()
  {
    var door = new McpDoor(new FakePermission()); var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage()); BrowserTools.Register(door, browser, new(new MemoryState<SessionLedger>(), new FakeProcessKeeper()));
    var caller = door.RegisterCaller(McpTests.Grant("browser.open") with { OwnerApplication = true, SessionId = null, Resources = ["settings:browser", "profiles:default"] }, (g, t, a, tier, ct) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "browser.open", JsonSerializer.SerializeToElement(new { url = "https://example.test" }))); Assert.Empty(factory.Created);
  }
}
