using System.Text.Json;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class W13IntegrationTests
{
  [Fact]
  public async Task ConnectedCallerReadsOnlyGrantedHistoryAndCannotClearAnotherOrigin()
  {
    var permissions = new FakePermission(); var door = new McpDoor(permissions);
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    var a = await browser.OpenAsync("https://allowed.test/a"); await browser.ObserveNavigationAsync(a.Id, a.Url, "Allowed");
    var b = await browser.OpenAsync("https://other.test/b"); await browser.ObserveNavigationAsync(b.Id, b.Url, "Other");
    BrowserWorkspaceTools.RegisterIfComposed(door, browser);
    var caller = door.RegisterCaller(McpTests.Grant("browser.workspace.read", "browser.workspace.change") with
    { OwnerApplication = false, SessionId = null, Resources = ["settings:browser", "profiles:default", "origins:https://allowed.test"] }, (_, _, _, _, _) => ValueTask.FromResult(true));
    var result = await door.CallAsync(caller.Id, "browser.workspace.read", JsonSerializer.SerializeToElement(new { command = "history" }));
    Assert.Equal("Allowed", Assert.Single(result.EnumerateArray()).GetProperty("Title").GetString()); Assert.Empty(permissions.Requests);
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "browser.workspace.change", JsonSerializer.SerializeToElement(new { command = "historyClear" })));
    Assert.Equal(2, browser.History("default").Length);
    var visit = browser.History("default").Single(v => v.Url == a.Url);
    await door.CallAsync(caller.Id, "browser.workspace.change", JsonSerializer.SerializeToElement(new { command = "historyForget", id = visit.Id }));
    Assert.Equal("Other", Assert.Single(browser.History("default")).Title);
  }
  [Fact]
  public async Task DownloadPathsRequireFileAuthorityInAdditionToTheTabAndOrigin()
  {
    var door = new McpDoor(new FakePermission()); var factory = new FakeBrowserFactory();
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var tab = await browser.OpenAsync("https://allowed.test/a"); BrowserWorkspaceTools.RegisterIfComposed(door, browser);
    var caller = door.RegisterCaller(McpTests.Grant("browser.workspace.read") with
    { OwnerApplication = false, SessionId = null, Resources = ["settings:browser", "profiles:default", "browser:" + tab.Id, "origins:https://allowed.test"] }, (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "browser.workspace.read", JsonSerializer.SerializeToElement(new { command = "downloads", window = tab.Id })));
    Assert.Empty(factory.Created[0].Page.Actions);
  }
  [Fact]
  public async Task SettingsToolAndBrowserUseTheSameStartPageWithoutWritingTheLegacyStore()
  {
    var door = new McpDoor(new FakePermission()); var legacy = new MemoryState<BrowserStartPage>();
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    door.Register("ui.workspace", (_, _, _) => ValueTask.FromResult(JsonSerializer.SerializeToElement(new { page = "Tasks" })));
    new BrowserStartPageSettings(legacy, browser).Register(door);
    var caller = door.RegisterCaller(McpTests.Grant("ui.workspace") with { Resources = ["settings:workspace"] }, (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { browserStartUrl = "https://allowed.test/start" }));
    Assert.Equal("https://allowed.test/start", browser.Read().StartUrl); Assert.Null(legacy.Value);
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { browserStartUrl = "" }));
    Assert.Equal("about:blank", browser.Read().StartUrl);
  }
}
