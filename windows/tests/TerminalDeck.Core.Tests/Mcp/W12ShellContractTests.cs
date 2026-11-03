using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Mcp;

public sealed class W12ShellContractTests
{
  [Fact] public async Task ShellReadsNeverPromptButPinMutationsUseTheExistingApprovalDoor()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission);
    var caller = door.RegisterCaller(McpTests.Grant("shell.read", "ui.workspace"), (_, _, _, _, _) => ValueTask.FromResult(true));
    door.Register("shell.read", (_, args, _) => ValueTask.FromResult(args));
    door.Register("ui.workspace", (_, args, _) => ValueTask.FromResult(args));
    await door.CallAsync(caller.Id, "shell.read", JsonSerializer.SerializeToElement(new { kind = "sidebar" }));
    Assert.Empty(permission.Requests);
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { sidebarAction = new { action = "pin-page", pageId = "Devices", pinned = true } }));
    Assert.Equal(McpTier.Act, Assert.Single(permission.Requests).Tier);
  }

  [Fact] public void RemovedInAppAlertsCannotBeReadThroughTools()
  {
    var spec = McpCatalogue.Load().Single(t => t.Id == "shell.read");
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(spec.InputSchema, JsonSerializer.SerializeToElement(new { kind = "alerts" })));
    McpSchema.Validate(spec.InputSchema, JsonSerializer.SerializeToElement(new { kind = "sidebar" }));
  }

  [Fact] public async Task TaskPopupPresentationUsesTheExistingActApproval()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission);
    var caller = door.RegisterCaller(McpTests.Grant("ui.workspace"), (_, _, _, _, _) => ValueTask.FromResult(true));
    door.Register("ui.workspace", (_, args, _) => ValueTask.FromResult(args));
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { taskPopup = new { taskId = "local:one", expanded = true, threadPane = "Activity", hideEmptyFields = true } }));
    Assert.Equal(McpTier.Act, Assert.Single(permission.Requests).Tier);
  }
  [Fact] public void PaneMovesGeometryAndConfirmationUseTheDeclaredSharedContract()
  {
    var spec = McpCatalogue.Load().Single(t => t.Id == "ui.workspace");
    foreach (var value in new object[] {
      new { windowAction = new { action = "move-pane", windowId = "one", otherWindowId = "two", edge = "above" } },
      new { windowAction = new { action = "focus-empty", windowId = "one", emptyPaneId = "empty:one" } },
      new { windowAction = new { action = "window-bounds", windowId = "one", x = -1200, y = 0, width = 900, height = 700 } },
      new { shellCommand = "session-delete-confirmation" }
    }) McpSchema.Validate(spec.InputSchema, JsonSerializer.SerializeToElement(value));
    Assert.Equal(McpTier.Alter, McpCatalogue.EffectiveTier(spec, JsonSerializer.SerializeToElement(new { shellCommand = "stop-exit" })));
    Assert.Equal(McpTier.Read, McpCatalogue.EffectiveTier(McpCatalogue.Load().Single(t => t.Id == "shell.read"), JsonSerializer.SerializeToElement(new { kind = "inspector", sessionId = "one" })));
  }
  [Theory]
  [InlineData("panel")]
  [InlineData("window")]
  public async Task PanelAndLegacyWindowRequestsUseTheSameActApproval(string presentation)
  {
    var permission = new FakePermission(); var door = new McpDoor(permission);
    var caller = door.RegisterCaller(McpTests.Grant("ui.workspace"), (_, _, _, _, _) => ValueTask.FromResult(true));
    door.Register("ui.workspace", (_, args, _) => ValueTask.FromResult(args));
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { settingsPresentation = presentation }));
    Assert.Equal(McpTier.Act, Assert.Single(permission.Requests).Tier);
  }
  [Theory]
  [InlineData("{\"settingsPresentation\":\"sheet\"}")]
  [InlineData("{\"sidebarAction\":{\"action\":\"pin-page\",\"pageId\":\"Store\",\"pinned\":true}}")]
  [InlineData("{\"sidebarAction\":{\"action\":\"geometry\",\"width\":999}}")]
  [InlineData("{\"windowAction\":{\"action\":\"rename\",\"title\":\"12345678901234567890123456789012345678901\"}}")]
  public void RemovedOrUnsupportedOptionsCannotSlipThroughTheSharedContract(string json)
  {
    var spec = McpCatalogue.Load().Single(t => t.Id == "ui.workspace"); using var args = JsonDocument.Parse(json);
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(spec.InputSchema, args.RootElement));
  }
}
