using System.Text.Json;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserBookmarksTests
{
  [Fact] public async Task BookmarksPersistPerProfileAndIsolatedTabsUseTheirProfile()
  {
    var store = new MemoryState<BrowserState>();
    await using var browser = new BrowserModel(store, new FakeBrowserFactory(), new FakeBrowserStorage());
    var work = await browser.CreateProfileAsync("Work");
    var saved = await browser.AddBookmarkAsync("default", "https://example.test/a", "Example", "https://example.test/icon.png");
    var repeated = await browser.AddBookmarkAsync("default", "https://example.test/a", "Repeat");
    Assert.Equal(saved.Id, repeated.Id); Assert.Single(browser.Bookmarks("default")); Assert.Empty(browser.Bookmarks(work.Id));
    var isolated = await browser.OpenAsync("https://example.test/a", true); Assert.Single(browser.Bookmarks(isolated.ProfileId));
    await browser.ShowBookmarkBarAsync(work.Id, true); Assert.True(browser.ShowsBookmarkBar(work.Id)); Assert.False(browser.ShowsBookmarkBar("default"));
    await using var restored = new BrowserModel(store, new FakeBrowserFactory(), new FakeBrowserStorage()); Assert.Equal(saved, Assert.Single(restored.Bookmarks("default"))); Assert.True(restored.ShowsBookmarkBar(work.Id));
    var copy = browser.Read(); copy.Bookmarks[0] = saved with { Title = "Changed" }; Assert.Equal("Example", browser.Bookmarks("default")[0].Title);
    await browser.RemoveBookmarkAsync(work.Id, saved.Id); Assert.Single(browser.Bookmarks("default"));
    await browser.RemoveBookmarkAsync("default", saved.Id); Assert.Empty(browser.Bookmarks("default"));
  }
  [Theory] [InlineData("about:blank")] [InlineData("file:///C:/secret")] [InlineData("https://user:pass@example.test")] [InlineData("https://start.deck.invalid/index.html")]
  public async Task InternalAndCredentialAddressesCannotBecomeBookmarks(string url)
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    await Assert.ThrowsAsync<ArgumentException>(async () => await browser.AddBookmarkAsync("default", url, "No")); Assert.Empty(browser.Bookmarks("default"));
  }
  [Fact] public async Task FailedSaveNeverChangesBookmarks()
  {
    var store = new MemoryState<BrowserState>(); await using var browser = new BrowserModel(store, new FakeBrowserFactory(), new FakeBrowserStorage());
    store.FailSave = true; await Assert.ThrowsAsync<IOException>(async () => await browser.AddBookmarkAsync("default", "https://example.test/", "Example")); Assert.Empty(browser.Bookmarks("default")); store.FailSave = false;
  }
  [Fact] public async Task BookmarkToolsUseTheExistingAlterApprovalAndReadStaysFree()
  {
    var permissions = new FakePermission(); var door = new McpDoor(permissions);
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage()); BrowserWorkspaceTools.RegisterIfComposed(door, browser);
    var caller = door.RegisterCaller(McpTests.Grant("browser.workspace.read", "browser.workspace.change") with { OwnerApplication = true, SessionId = null }, (g, t, a, tier, ct) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "browser.workspace.change", JsonSerializer.SerializeToElement(new { command = "bookmarkAdd", url = "https://example.test/", title = "Example" }));
    Assert.Equal(McpTier.Alter, permissions.Requests[^1].Tier); var prior = permissions.Requests.Count;
    var result = await door.CallAsync(caller.Id, "browser.workspace.read", JsonSerializer.SerializeToElement(new { command = "bookmarks" })); Assert.Equal(prior, permissions.Requests.Count); Assert.Single(result.GetProperty("bookmarks").EnumerateArray());
    await door.CallAsync(caller.Id, "browser.workspace.change", JsonSerializer.SerializeToElement(new { command = "bookmarkRemove", id = browser.Bookmarks("default")[0].Id })); Assert.Empty(browser.Bookmarks("default"));
  }
}
