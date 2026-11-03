using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Mcp;

public sealed class W10WorkspaceContractTests
{
  private static JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);

  [Fact]
  public async Task CombinedSettingsAndWindowActionsReachTheSameGuardedDoor()
  {
    var permission = new FakePermission();
    var door = new McpDoor(permission);
    var caller = door.RegisterCaller(McpTests.Grant("ui.workspace"), (_, _, _, _, _) => ValueTask.FromResult(true));
    var calls = 0;
    door.Register("ui.workspace", (_, args, _) => { calls++; return ValueTask.FromResult(args.Clone()); });
    await door.CallAsync(caller.Id, "ui.workspace", Args(new { }));
    Assert.Empty(permission.Requests);
    var args = Args(new { settingsSection = "appearance", settingsPresentation = "window", settingsSearch = "theme", windowAction = new { action = "rename", windowId = "session-window", title = "Review" } });
    var result = await door.CallAsync(caller.Id, "ui_workspace", args);
    Assert.Equal("Review", result.GetProperty("windowAction").GetProperty("title").GetString());
    Assert.Equal(McpTier.Act, Assert.Single(permission.Requests).Tier);
    permission.Answer = r => new(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false);
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "ui.workspace", Args(new { settingsPresentation = "window" })));
    Assert.Equal(2, calls);
  }

  [Theory]
  [InlineData("{\"windowAction\":{\"action\":\"unknown\"}}")]
  [InlineData("{\"windowAction\":{\"action\":\"resize\",\"ratio\":0.1}}")]
  [InlineData("{\"windowAction\":{\"action\":\"rename\",\"caller\":\"owner\"}}")]
  [InlineData("{\"settingsPresentation\":\"island\"}")]
  public void CombinedContractStillRefusesUnlistedOrOutOfRangeArguments(string json)
  {
    var spec = McpCatalogue.Load().Single(t => t.Id == "ui.workspace");
    using var args = JsonDocument.Parse(json);
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(spec.InputSchema, args.RootElement));
  }
}
