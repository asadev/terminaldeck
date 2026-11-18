using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Chats;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Settings;

public sealed class LaunchPermissionDefaultsTests
{
  [Theory]
  [InlineData("shell")]
  [InlineData("custom:fixture")]
  public void NonCodingStartsKeepTheirLegacyFallback(string provider)
  {
    var preferences = LaunchPermissions.With(new(DefaultPermission: AiPermissionMode.Bypass), "claude", AiPermissionMode.Plan);
    var owner = new GeneralSettings(new Store { Value = preferences });
    Assert.Equal(ChatPermissionModes.DefaultFor(provider, preferences.DefaultPermission), owner.NewChatPermission(provider));
    Assert.Throws<ArgumentException>(() => LaunchPermissions.With(preferences, provider, AiPermissionMode.Bypass));
  }
  private sealed class Store : IStateStore<GeneralPreferences>
  {
    public GeneralPreferences? Value;
    public int Writes;
    public GeneralPreferences? Load() => Value;
    public void Save(GeneralPreferences value) { Value = value; Writes++; }
  }

  [Fact] public void LegacySettingsKeepTheirGlobalFallbackAndNewFieldsRoundTrip()
  {
    var legacy = JsonSerializer.Deserialize<GeneralPreferences>("{\"DefaultPermission\":1,\"CopyOnSelect\":true}")!;
    Assert.Null(legacy.LaunchPermissions);
    foreach (var provider in new[] { "claude", "codex", "gemini" })
      Assert.Equal(ChatPermissionModes.DefaultFor(provider, legacy.DefaultPermission), LaunchPermissions.For(provider, legacy));
    var next = LaunchPermissions.With(legacy, "claude", AiPermissionMode.Plan);
    var reopened = JsonSerializer.Deserialize<GeneralPreferences>(JsonSerializer.Serialize(next))!;
    Assert.Equal(AiPermissionMode.Plan, LaunchPermissions.For("claude", reopened));
    Assert.True(reopened.CopyOnSelect);
    Assert.Equal(legacy.DefaultPermission, reopened.DefaultPermission);
  }

  [Fact] public void OverridesAreIndependentAndClearingOneRestoresGlobalInheritance()
  {
    var preferences = new GeneralPreferences(DefaultPermission: AiPermissionMode.Ask);
    preferences = LaunchPermissions.With(preferences, "claude", AiPermissionMode.Auto);
    preferences = LaunchPermissions.With(preferences, "codex", AiPermissionMode.Plan);
    Assert.Equal(AiPermissionMode.Auto, LaunchPermissions.For("claude", preferences));
    Assert.Equal(AiPermissionMode.Plan, LaunchPermissions.For("codex", preferences));
    Assert.Equal(AiPermissionMode.Ask, LaunchPermissions.For("gemini", preferences));
    preferences = LaunchPermissions.With(preferences, "claude", null);
    Assert.Equal(AiPermissionMode.Ask, LaunchPermissions.For("claude", preferences));
    Assert.Equal(AiPermissionMode.Plan, LaunchPermissions.For("codex", preferences));
  }

  [Theory]
  [InlineData("codex", AiPermissionMode.Auto)]
  [InlineData("gemini", AiPermissionMode.Auto)]
  [InlineData("claude", (AiPermissionMode)999)]
  [InlineData("shell", AiPermissionMode.Ask)]
  public void UnsupportedExplicitChoiceIsRefusedOnSaveAndLaunch(string provider, AiPermissionMode mode)
  {
    var store = new Store(); var owner = new GeneralSettings(store);
    Assert.Throws<ArgumentException>(() => owner.Save(new(LaunchPermissions: [new(provider, mode)])));
    Assert.Equal(0, store.Writes);
    Assert.Throws<ArgumentException>(() => LaunchPermissions.With(new(), provider, mode));
    store.Value = new(LaunchPermissions: [new(provider, mode)]);
    Assert.Throws<ArgumentException>(() => owner.NewChatPermission(provider));
  }

  [Fact] public void DuplicateSavedOverridesAreRefusedInsteadOfPickingAWiderMode()
  {
    var preferences = new GeneralPreferences(LaunchPermissions: [new("claude", AiPermissionMode.Plan), new("claude", AiPermissionMode.Bypass)]);
    Assert.Throws<ArgumentException>(() => new GeneralSettings(new Store()).Save(preferences));
    Assert.Throws<ArgumentException>(() => LaunchPermissions.For("claude", preferences));
  }

  [Fact] public void GeneralPatchIsAtomicAndPreservesUnrelatedChoices()
  {
    var store = new Store { Value = new(CopyOnSelect: true, DefaultPermission: AiPermissionMode.Ask, LaunchModels: [new("claude", "claude-opus-5-5", "high")]) };
    var owner = new GeneralSettings(store);
    owner.Patch(JsonSerializer.SerializeToElement(new { launchPermissions = new { claude = "Plan", codex = "AcceptEdits" } }));
    var before = owner.Read();
    Assert.True(before.CopyOnSelect); Assert.Equal("high", Assert.Single(before.LaunchModels!).Effort);
    Assert.Throws<ArgumentException>(() => owner.Patch(JsonSerializer.SerializeToElement(new { copyOnSelect = false, launchPermissions = new { gemini = "Auto" } })));
    Assert.Same(before, owner.Read()); Assert.Equal(1, store.Writes);
    owner.Patch(JsonSerializer.SerializeToElement(new { launchPermissions = new { claude = (string?)null } }));
    Assert.Equal(AiPermissionMode.Ask, owner.NewChatPermission("claude"));
    Assert.Equal(AiPermissionMode.AcceptEdits, owner.NewChatPermission("codex"));
  }

  [Fact] public async Task LaunchToolReadsFreelyAndPermissionOnlyWritePreservesModelAndEffort()
  {
    var store = new Store { Value = new(CopyOnSelect: true, LaunchModels: [new("claude", "claude-opus-5-5", "high")]) };
    var general = new GeneralSettings(store); var permission = new FakePermission(); var door = new McpDoor(permission);
    Register(door, general);
    var caller = door.RegisterCaller(McpTests.Grant("settings.launch_models"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "settings.launch_models", JsonSerializer.SerializeToElement(new { action = "read" }));
    Assert.Empty(permission.Requests); Assert.Equal(0, store.Writes);
    var result = await door.CallAsync(caller.Id, "settings.launch_models", JsonSerializer.SerializeToElement(new { action = "set", agent = "claude", permissionMode = "Plan" }));
    Assert.Single(permission.Requests); Assert.True(general.Read().CopyOnSelect);
    Assert.Equal(new LaunchModelChoice("claude", "claude-opus-5-5", "high"), Assert.Single(general.Read().LaunchModels!));
    Assert.Equal("Plan", result.EnumerateArray().Single(row => row.GetProperty("agent").GetString() == "claude").GetProperty("permissionMode").GetString());
    await door.CallAsync(caller.Id, "settings.launch_models", JsonSerializer.SerializeToElement(new { action = "set", agent = "claude", effort = "max" }));
    Assert.Equal(AiPermissionMode.Plan, general.NewChatPermission("claude"));
    await door.CallAsync(caller.Id, "settings.launch_models", JsonSerializer.SerializeToElement(new { action = "set", agent = "claude", permissionMode = (string?)null }));
    Assert.Empty(general.Read().LaunchPermissions!);
  }

  [Theory]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task LaunchToolRefusesUnsupportedModeWithoutSavingOtherChanges(string provider)
  {
    var store = new Store(); var general = new GeneralSettings(store); var door = new McpDoor(new FakePermission()); Register(door, general);
    var caller = door.RegisterCaller(McpTests.Grant("settings.launch_models"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<ArgumentException>(async () => await door.CallAsync(caller.Id, "settings.launch_models", JsonSerializer.SerializeToElement(new { action = "set", agent = provider, model = "test-model", permissionMode = "Auto" })));
    Assert.Equal(0, store.Writes);
  }

  [Fact] public async Task DeniedPermissionChangeNeverWritesSettings()
  {
    var store = new Store(); var general = new GeneralSettings(store);
    var permission = new FakePermission { Answer = request => new(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false) };
    var door = new McpDoor(permission); Register(door, general);
    var caller = door.RegisterCaller(McpTests.Grant("settings.launch_models"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "settings.launch_models", JsonSerializer.SerializeToElement(new { action = "set", agent = "claude", permissionMode = "Bypass" })));
    Assert.Equal(0, store.Writes);
  }

  [Fact] public async Task NewChatOwnerUsesSavedOverrideWithoutChangingExistingChat()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    var before = fixture.Chats.Get(fixture.Chat.Definition.Id).Definition.PermissionMode;
    var general = new GeneralSettings(new JsonStateStore<GeneralPreferences>(fixture.Root, "general-settings"));
    general.Save(LaunchPermissions.With(general.Read(), "claude", AiPermissionMode.Plan));
    var created = await fixture.Chats.CreateAsync("claude", fixture.Root.DirectoryPath, fixture.Account.Id);
    Assert.Equal(AiPermissionMode.Plan, created.Definition.PermissionMode);
    Assert.Equal(before, fixture.Chats.Get(fixture.Chat.Definition.Id).Definition.PermissionMode);
    Assert.Equal(AiPermissionMode.Plan, GeneralSettings.NewChatPermission(fixture.Root, "claude"));
    Assert.Equal(0, fixture.Keeper.Starts);
  }

  private static void Register(McpDoor door, GeneralSettings general) =>
    AccountMcp.Register(door, new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]), null, general, () => [], () => [], () => [], _ => false);
}
