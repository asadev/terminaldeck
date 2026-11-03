using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserWorkspaceTests
{
  [Fact] public async Task HistoryIsProfileScopedAndPrivateTabsNeverLeaveVisits()
  {
    var state = new MemoryState<BrowserState>(); await using var browser = new BrowserModel(state, new FakeBrowserFactory(), new FakeBrowserStorage());
    var work = await browser.CreateProfileAsync("Work");
    var normal = await browser.OpenAsync("https://example.test/a"); var other = await browser.OpenAsync("https://example.test/a", profileId: work.Id); var isolated = await browser.OpenAsync("https://example.test/private", true);
    await browser.ObserveNavigationAsync(normal.Id, normal.Url, "Ordinary");
    await browser.ObserveNavigationAsync(normal.Id, normal.Url, "Updated title");
    await browser.ObserveNavigationAsync(other.Id, other.Url, "Work");
    await browser.ObserveNavigationAsync(isolated.Id, isolated.Url, "Secret");
    Assert.Equal("Updated title", Assert.Single(browser.History("default")).Title); Assert.Single(browser.History(work.Id)); Assert.Equal(2, state.Value!.History.Length);
    var snapshot = browser.Read(); snapshot.History[0] = snapshot.History[0] with { Title = "tampered" }; Assert.DoesNotContain(browser.History("default"), v => v.Title == "tampered");
    await browser.ForgetHistoryAsync("default", query: "updated"); Assert.Empty(browser.History("default")); Assert.Single(browser.History(work.Id));
  }
  [Fact] public async Task NewTabIsInsertedAfterCurrentAndLastCloseRemainsClosed()
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    var a = await browser.OpenAsync("about:blank"); var b = await browser.OpenAsync("about:blank"); await browser.SelectAsync(a.Id); var c = await browser.OpenAsync("about:blank");
    Assert.Equal(new[] { a.Id, c.Id, b.Id }, browser.Read().Tabs.Select(t => t.Id));
    foreach (var tab in browser.Read().Tabs) await browser.CloseAsync(tab.Id);
    Assert.Empty(browser.Read().Tabs); Assert.Null(browser.Read().SelectedTabId);
  }
  [Fact] public async Task StoreSwitchKeepsLogicalWindowBindingAndPositionButRecreatesCookieStore()
  {
    var factory = new FakeBrowserFactory(); var storage = new FakeBrowserStorage(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, storage);
    var tab = await browser.OpenAsync("https://example.test/a", sessionId: "s"); var work = await browser.CreateProfileAsync("Work");
    await browser.ChangeStoreAsync(tab.Id, work.Id, true);
    var switched = browser.Get(tab.Id); Assert.Equal(tab.Window, switched.Window); Assert.Equal(tab.SessionSlot, switched.SessionSlot); Assert.Equal("s", switched.SessionId); Assert.Equal(work.Id, switched.ProfileId); Assert.True(switched.Isolated);
    Assert.True(factory.Created[0].Page.Disposed); Assert.Equal(2, factory.Created.Count); Assert.Single(storage.PrivateStores);
    await browser.ChangeStoreAsync(tab.Id, "default", false); Assert.Empty(storage.PrivateStores); Assert.Single(browser.Read().Tabs); Assert.Equal("default", browser.Read().ActiveProfileId);
  }
  [Fact] public async Task StartPagePersistsAndRejectsUnsafeAddresses()
  {
    var state = new MemoryState<BrowserState>(); await using var browser = new BrowserModel(state, new FakeBrowserFactory(), new FakeBrowserStorage());
    await browser.SetStartUrlAsync("https://example.test/start"); Assert.Equal("https://example.test/start", state.Value!.StartUrl);
    await Assert.ThrowsAsync<ArgumentException>(async () => await browser.SetStartUrlAsync("file:///private")); Assert.Equal("https://example.test/start", browser.Read().StartUrl);
  }
  [Fact] public async Task FailedStoreSaveLeavesTheOriginalPageAlive()
  {
    var state = new MemoryState<BrowserState>(); var factory = new FakeBrowserFactory();
    await using var browser = new BrowserModel(state, factory, new FakeBrowserStorage());
    var tab = await browser.OpenAsync("https://example.test"); state.FailSave = true;
    await Assert.ThrowsAsync<IOException>(async () => await browser.ChangeStoreAsync(tab.Id, "default", true));
    Assert.False(factory.Created[0].Page.Disposed); Assert.False(browser.Get(tab.Id).Isolated); Assert.Single(factory.Created);
    state.FailSave = false;
  }
  [Fact] public async Task FailedReplacementRestoresTheOriginalStoreAndBinding()
  {
    var factory = new FailOnceFactory(); var storage = new FakeBrowserStorage();
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, storage);
    var tab = await browser.OpenAsync("https://example.test", sessionId: "s"); factory.FailNext = true;
    await Assert.ThrowsAsync<IOException>(async () => await browser.ChangeStoreAsync(tab.Id, "default", true));
    Assert.False(browser.Get(tab.Id).Isolated); Assert.Equal(tab.SessionSlot, browser.Get(tab.Id).SessionSlot); Assert.Empty(storage.PrivateStores); Assert.Equal(3, factory.Calls);
  }
  [Fact] public async Task NavigationRemainsPinnedUntilExplicitHumanTakeover()
  {
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var tab = await browser.OpenAsync("https://example.test/a");
    await browser.PerformAsync(tab.Id, BrowserPageAction.Step, System.Text.Json.JsonSerializer.SerializeToElement(new { }));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.NavigateAsync(tab.Id, "https://other.test/"));
    await browser.TakeHumanControlAsync(tab.Id); await browser.NavigateAsync(tab.Id, "https://other.test/");
    Assert.Null(browser.Get(tab.Id).AutomationOrigin); Assert.Contains(BrowserPageAction.TakeOver, factory.Created[0].Page.Actions);
  }
  [Fact] public void ViewportsUseMacDimensionsAndLandscapeIsReversible()
  {
    Assert.Equal(new[] { (0,0),(375,667),(390,844),(768,1024),(1024,1366),(1280,800),(1440,900) }, BrowserViewport.Presets.Select(v => (v.Width,v.Height)));
    var custom = BrowserViewport.Custom(800, 600); Assert.Equal(custom, custom.Landscape().Landscape()); Assert.Throws<ArgumentException>(() => BrowserViewport.Custom(0, 600));
  }
  private sealed class FailOnceFactory : IBrowserSurfaceFactory
  {
    public bool FailNext { get; set; }
    public int Calls { get; private set; }
    public ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken cancellationToken)
    {
      Calls++; if (FailNext) { FailNext = false; throw new IOException("Synthetic replacement failure."); }
      return ValueTask.FromResult<IBrowserPage>(new FakeBrowserPage(options.TabId));
    }
  }
}
