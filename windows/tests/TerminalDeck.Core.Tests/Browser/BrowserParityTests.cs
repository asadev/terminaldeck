using System.Text.Json;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserParityTests
{
  [Fact]
  public async Task BackgroundOpenAndCallerSelectionKeepThePersonsTabAndSurfaces()
  {
    var factory = new FakeBrowserFactory();
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var human = await browser.OpenAsync("https://example.test/person");
    var agent = await browser.OpenAsync("https://example.test/agent", sessionId: "work", select: false);
    browser.SelectForCaller("decker", agent.Id);
    Assert.Equal(human.Id, browser.Read().SelectedTabId);
    Assert.Equal(agent.Id, browser.CallerSelection("decker"));
    Assert.Null(browser.CallerSelection("other"));
    var popup = await browser.OpenPopupAsync(agent.Id, "https://example.test/popup", select: false);
    Assert.Equal(human.Id, browser.Read().SelectedTabId);
    Assert.Equal("work", popup.SessionId);
    Assert.Equal(3, factory.Created.Count);
    Assert.All(factory.Created, page => Assert.Equal(1, page.Page.Navigations));
    await browser.CloseAsync(agent.Id);
    Assert.Null(browser.CallerSelection("decker"));
    Assert.Equal(human.Id, browser.Read().SelectedTabId);
  }

  [Fact]
  public async Task ClosedTabCannotReturnAfterRestoreAndEmptyWorkspaceStaysEmpty()
  {
    var state = new MemoryState<BrowserState>();
    var browser = new BrowserModel(state, new FakeBrowserFactory(), new FakeBrowserStorage());
    var closed = await browser.OpenAsync("about:blank");
    await browser.CloseAsync(closed.Id); await browser.DisposeAsync();
    var factory = new FakeBrowserFactory();
    await using var restarted = new BrowserModel(state, factory, new FakeBrowserStorage());
    await restarted.RestoreAsync(); await restarted.RestoreAsync();
    Assert.Empty(restarted.Read().Tabs); Assert.Empty(factory.Created);
  }

  [Fact]
  public async Task DriverIsCallerSpecificAndClearedWhenPersonTakesControl()
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    var tab = await browser.OpenAsync("https://example.test");
    browser.SetDriver(tab.Id, "Decker"); Assert.Equal("Decker", browser.Driver(tab.Id));
    await browser.TakeHumanControlAsync(tab.Id); Assert.Null(browser.Driver(tab.Id));
    var grant = new McpGrant("caller", "synthetic-session", null, true, AiPermissionMode.Ask, [], [], [], DateTimeOffset.MaxValue, SeatId: "decker");
    Assert.Equal("decker", BrowserModel.DriverLabel(grant));
    Assert.Equal("Hoot", BrowserModel.DriverLabel(grant with { SeatId = "orchestrator" }));
    Assert.DoesNotContain("Hoot", BrowserModel.DriverLabel(grant with { SeatId = null }));
  }

  [Fact]
  public async Task BatchUsesOneApprovedDoorCallAndFileUploadStillNeedsAFileGrant()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission);
    var factory = new FakeBrowserFactory();
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var tab = await browser.OpenAsync("https://example.test");
    BrowserTools.RegisterWithSessionLookup(door, browser, _ => throw new InvalidOperationException());
    var grant = McpTests.Grant("browser.batch", "browser.upload") with { OwnerApplication = true, SessionId = null, Resources = ["browser:*", "profiles:default", "origins:https://example.test"] };
    var caller = door.RegisterCaller(grant, (_, _, _, _, _) => ValueTask.FromResult(true));
    var result = await door.CallAsync(caller.Id, "browser.batch", JsonSerializer.SerializeToElement(new { window = tab.Id, steps = new object[] { new { action = "read", within = "#dialog" }, new { action = "step", verb = "click", selector = "button" } } }));
    Assert.True(result.GetProperty("done").GetBoolean()); Assert.Equal(2, result.GetProperty("completed").GetInt32());
    Assert.Equal([BrowserPageAction.Read, BrowserPageAction.Step], factory.Created[0].Page.Actions);
    Assert.Single(permission.Requests);
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(caller.Id, "browser.upload", JsonSerializer.SerializeToElement(new { window = tab.Id, selector = "input[type=file]", paths = new[] { Path.Combine(Path.GetTempPath(), "not-granted.txt") } })).AsTask());
    Assert.Equal(2, factory.Created[0].Page.Actions.Count);
  }

  [Fact]
  public void ReadStepAndBatchContractsExposeScopedPagingLocatorsAndBoundedSteps()
  {
    var specs = McpCatalogue.Load();
    var read = specs.Single(s => s.Id == "browser.read").InputSchema;
    var step = specs.Single(s => s.Id == "browser.step").InputSchema;
    var batch = specs.Single(s => s.Id == "browser.batch");
    Assert.True(read.GetProperty("properties").TryGetProperty("within", out _));
    Assert.Equal(200, read.GetProperty("properties").GetProperty("limit").GetProperty("maximum").GetInt32());
    Assert.True(step.GetProperty("properties").TryGetProperty("nth", out _));
    Assert.Equal(McpTier.Act, batch.Tier);
    Assert.Equal(20, batch.InputSchema.GetProperty("properties").GetProperty("steps").GetProperty("maxItems").GetInt32());
    Assert.Throws<ArgumentException>(() => BrowserDomAutomation.Step(JsonSerializer.SerializeToElement(new { verb = "evaluate", selector = "button" })));

  }
}
