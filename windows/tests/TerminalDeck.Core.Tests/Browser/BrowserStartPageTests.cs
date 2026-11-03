using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserStartPageTests
{
  [Theory]
  [InlineData("", "")]
  [InlineData("   ", "")]
  [InlineData(" https://example.com ", "https://example.com/")]
  [InlineData("http://localhost:5199/path", "http://localhost:5199/path")]
  public void AcceptsBlankAndWebPages(string value, string expected) => Assert.Equal(expected, BrowserStartPage.Validate(value));

  [Theory]
  [InlineData("file:///etc/passwd")]
  [InlineData("javascript:alert(1)")]
  [InlineData("https://username:secret@example.com")]
  [InlineData("example.com")]
  [InlineData("ms-settings:notifications")]
  public void RejectsNonWebAddressesAndCredentials(string value) => Assert.Throws<ArgumentException>(() => BrowserStartPage.Validate(value));
}

public sealed class BrowserStartPageToolTests
{
  private sealed class Store : TerminalDeck.Core.Storage.IStateStore<BrowserStartPage>
  {
    public BrowserStartPage? State;
    public BrowserStartPage? Load() => State;
    public void Save(BrowserStartPage state) => State = state;
  }
  private sealed class Permissions : TerminalDeck.Core.Mcp.IMcpPermissionBroker
  {
    public int Calls;
    public ValueTask<TerminalDeck.Core.Mcp.McpPermissionProof> AuthorizeAsync(TerminalDeck.Core.Mcp.McpPermissionRequest request, CancellationToken ct)
    {
      Calls++;
      return ValueTask.FromResult(new TerminalDeck.Core.Mcp.McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true));
    }
  }
  [Fact]
  public async Task ReadsFreelyAndWritesOnceThroughTheExistingDoor()
  {
    var permissions = new Permissions(); var store = new Store();
    var door = new TerminalDeck.Core.Mcp.McpDoor(permissions);
    door.Register("ui.workspace", (_, _, _) => ValueTask.FromResult(System.Text.Json.JsonSerializer.SerializeToElement(new { page = "Tasks" })));
    new BrowserStartPageSettings(store).Register(door);
    var caller = door.RegisterCaller(new("w13", null, null, true, TerminalDeck.Core.Mcp.AiPermissionMode.Ask,
      ["ui.workspace"], Enum.GetValues<TerminalDeck.Core.Mcp.McpTier>(), ["settings:workspace"], DateTimeOffset.UtcNow.AddMinutes(1), true), (_, _, _, _, _) => ValueTask.FromResult(true));
    var result = await door.CallAsync(caller.Id, "ui.workspace", System.Text.Json.JsonSerializer.SerializeToElement(new { }));
    Assert.Equal("", result.GetProperty("browserStartUrl").GetString()); Assert.Equal(0, permissions.Calls);
    result = await door.CallAsync(caller.Id, "ui.workspace", System.Text.Json.JsonSerializer.SerializeToElement(new { browserStartUrl = "https://example.com" }));
    Assert.Equal("https://example.com/", store.State?.Url); Assert.Equal(1, permissions.Calls);
    Assert.Equal("Tasks", result.GetProperty("page").GetString());
  }
  [Fact]
  public async Task ScopedCallerCannotReadOrChangeSettings()
  {
    var permissions = new Permissions(); var store = new Store();
    var door = new TerminalDeck.Core.Mcp.McpDoor(permissions); new BrowserStartPageSettings(store).Register(door);
    var caller = door.RegisterCaller(new("scoped", null, null, true, TerminalDeck.Core.Mcp.AiPermissionMode.Ask,
      ["ui.workspace"], Enum.GetValues<TerminalDeck.Core.Mcp.McpTier>(), ["projects:independent"], DateTimeOffset.UtcNow.AddMinutes(1), true), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<TerminalDeck.Core.Mcp.McpRefusal>(async () => await door.CallAsync(caller.Id, "ui.workspace", System.Text.Json.JsonSerializer.SerializeToElement(new { })));
    Assert.Null(store.State);
  }
}
