using System.Text.Json;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Chats;

namespace TerminalDeck.Core.Tests.Settings;

[Collection("Windows chat")]
public sealed class W14GeneralSettingsTests
{
  [Theory]
  [InlineData(true)]
  [InlineData(false)]
  public async Task AutoNamingHonorsSavedChoiceInKeeperAfterRestart(bool enabled)
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    new GeneralSettings(new JsonStateStore<GeneralPreferences>(fixture.Root, "general-settings")).Save(new(AutoNameSessions: enabled));
    await fixture.RestartAsync();
    var id = fixture.Chat.Definition.Id;
    await fixture.Chats.SendAsync(id, Guid.NewGuid().ToString(), "Plan the new dashboard");
    Assert.Equal(enabled ? "Plan the new dashboard" : fixture.Chat.Definition.Title, fixture.Chats.Get(id).Definition.Title);
  }
  [Fact] public async Task CustomTitleSurvivesAutoNamingAndFirstMessage()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    await fixture.Chats.RenameAsync(fixture.Chat.Definition.Id, "My title");
    await fixture.Chats.SendAsync(fixture.Chat.Definition.Id, Guid.NewGuid().ToString(), "Do not replace my title");
    Assert.Equal("My title", fixture.Chats.Get(fixture.Chat.Definition.Id).Definition.Title);
  }
  [Fact] public void PartialChangesRoundTripAndRejectInvalidPatchBeforeSaving()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "w14-settings-" + Guid.NewGuid()));
    try {
      var service = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
      Assert.Equal(new(), service.Read());
      service.Patch(JsonSerializer.SerializeToElement(new { copyOnSelect = true, keepAwake = true }));
      var next = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
      Assert.Equal(new GeneralPreferences(true, true, true), next.Read());
      Assert.Throws<ArgumentException>(() => next.Patch(JsonSerializer.SerializeToElement(new { keepAwake = false, unknown = true })));
      Assert.Equal(new GeneralPreferences(true, true, true), service.Read());
      Assert.Throws<ArgumentException>(() => next.Patch(JsonSerializer.SerializeToElement(new { copyOnSelect = "yes" })));
      Assert.False(GeneralSettings.ShouldAutoName(root, true, 0));
      Assert.False(GeneralSettings.ShouldAutoName(root, false, 1));
    } finally { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task ToolsReadFreelyAndChangesRequireExistingApprovalWithoutTouchingSessions()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    var permissions = new FakePermission(); var door = new McpDoor(permissions);
    var settings = new GeneralSettings(new JsonStateStore<GeneralPreferences>(fixture.Root, "general-settings"));
    var confirmation = true; var checks = 0;
    GeneralSettingsTools.Register(settings, door, () => confirmation, value => confirmation = value,
      () => "0.20.2.44014", () => { checks++; return Task.FromResult("No update source configured."); });
    var caller = door.RegisterCaller(new("w14-settings", null, null, true, AiPermissionMode.Ask,
      ["ui.workspace"], [McpTier.Read, McpTier.Act], ["settings:workspace"], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var read = await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { }));
    Assert.Empty(permissions.Requests); Assert.True(read.GetProperty("generalSettings").GetProperty("autoNameSessions").GetBoolean());
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { generalSettings = new { copyOnSelect = true, confirmCloseWorking = false } }));
    Assert.Single(permissions.Requests); Assert.True(settings.Read().CopyOnSelect); Assert.False(confirmation);
    await door.CallAsync(caller.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { checkForUpdates = true }));
    Assert.Equal(2, permissions.Requests.Count); Assert.Equal(1, checks); Assert.Empty(fixture.Chats.Get(fixture.Chat.Definition.Id).Messages);
    var plan = door.RegisterCaller(new("w14-plan", null, null, true, AiPermissionMode.Plan,
      ["ui.workspace"], [McpTier.Read, McpTier.Act], ["settings:workspace"], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(plan.Id, "ui.workspace", JsonSerializer.SerializeToElement(new { generalSettings = new { copyOnSelect = false } })));
    Assert.True(settings.Read().CopyOnSelect);
  }

}
