using System.Collections.Immutable;
using System.Net;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class UmerAccountsTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "umer-accounts-" + Guid.NewGuid().ToString("N")));
  public void Dispose() { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }

  [Fact] public void OutOfTheBoxEveryAiStartsOnItsTopModelAndHighestLevel()
  {
    Assert.Equal(("claude-opus-5-5", "xhigh"), LaunchDefaults.For("claude", (GeneralPreferences?)null));
    Assert.Equal("Opus 5.5 · Extra high", ModelCatalog.Label("claude", "claude-opus-5-5", "xhigh"));
    Assert.Equal(("gpt-6.1-sol", "max"), LaunchDefaults.For("codex", (GeneralPreferences?)null));
    Assert.Equal(("gemini-3-pro-preview", (string?)null), LaunchDefaults.For("gemini", (GeneralPreferences?)null));
  }
  [Fact] public void NoPickerOrChipEverSaysDefault()
  {
    foreach (var provider in new[] { "claude", "codex", "gemini" })
    {
      Assert.NotEmpty(ModelCatalog.For(provider));
      Assert.DoesNotContain(ModelCatalog.For(provider), m => m.Name.Contains("default", StringComparison.OrdinalIgnoreCase));
      var live = new[] { new ProviderModel("default", "Default (recommended)", 0), new ProviderModel("claude-opus-5-5", "Opus 5.5", 0) };
      Assert.DoesNotContain(ModelCatalog.Merge(provider, live), m => m.Name.Contains("default", StringComparison.OrdinalIgnoreCase));
    }
    Assert.Contains(ModelCatalog.Merge("claude", [new("claude-sonnet-5-5", "Sonnet 5.5", 0)], keep: "claude-opus-5-5"), m => m.Name == "Opus 5.5");
    Assert.Equal("Extra high", ModelCatalog.EffortName("xhigh"));
    Assert.Equal(["low", "medium", "high", "xhigh", "max"], ModelEfforts.For("claude", null));
  }
  [Fact] public void SettingsHoldTheAppWideChoiceAndNewChatsTakeIt()
  {
    var settings = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
    settings.Patch(JsonSerializer.SerializeToElement(new { launchModels = new { claude = new { model = "claude-sonnet-5-5", effort = "high" } } }));
    Assert.Equal(("claude-sonnet-5-5", "high"), LaunchDefaults.For("claude", root));
    Assert.Equal(new ChatOptions("claude-sonnet-5-5", "high"), LaunchDefaults.Fill("claude", new(), root));
    Assert.Equal(new ChatOptions("claude-haiku-5-5", "low"), LaunchDefaults.Fill("claude", new("claude-haiku-5-5", "low"), root));
    Assert.Equal(new ChatOptions("gemini-3-pro-preview", ""), LaunchDefaults.Fill("gemini", new(), root));
    Assert.Throws<ArgumentException>(() => settings.Patch(JsonSerializer.SerializeToElement(new { launchModels = new { claude = new { model = "x", effort = "ultra" } } })));
  }
  [Fact] public void SessionsAcceptTheMaxLevel() =>
    new TerminalDeck.Core.Sessions.SessionDefinition(Guid.NewGuid().ToString(), "claude", root.DirectoryPath, "t", Effort: "max").Validate();

  [Fact] public void FolderDropdownListsProjectsRecentsAndHomeOnceEach()
  {
    var projects = new[] { new Project("p1", "CRM", ["C:/work/crm", "C:/work/crm-api"]), new Project("p2", "Closed", ["C:/old"], IsOpen: false) };
    var rows = NewSessionFolders.Choices(projects, ["C:/work/crm", "C:/tmp/scratch"], "C:/Users/umer");
    Assert.Equal(["C:/work/crm", "C:/work/crm-api", "C:/tmp/scratch", "C:/Users/umer"], rows.Select(r => r.Path));
    Assert.Equal(FolderChoiceKind.Home, rows[^1].Kind);
    Assert.Single(NewSessionFolders.Choices(projects, [], "C:/Users/umer", "api"));
  }
  [Fact] public void FolderDropdownTreatsSlashStylesAsOneFolderAndHidesAppDataFolders()
  {
    var projects = new[] { new Project("p1", "Review", ["C:\\TD\\review\\Sample project"]) };
    var rows = NewSessionFolders.Choices(projects,
      ["C:/TD/review/Sample project", "C:/TD/captest/scenarios", "C:\\TD\\captest\\scenarios\\", "C:\\Data\\TD\\accounts\\abc\\claude"],
      "C:\\Users\\sm", dataRoot: "C:\\Data\\TD");
    Assert.Equal(["C:\\TD\\review\\Sample project", "C:/TD/captest/scenarios", "C:\\Users\\sm"], rows.Select(r => r.Path));
  }

  [Fact] public async Task ApiAccountKeepsItsKeyOnlyInTheSecureStoreAndIsReadyWithoutSignIn()
  {
    var provider = new FakeAccountProvider("claude"); var accounts = new AccountService(new MemoryState<AccountState>(), [provider, new FakeAccountProvider("codex")]);
    var secrets = new TestSecretStore(); var api = new ApiAccountService(accounts, new AccountCredentials(secrets, root), root, new HttpClient(new Answer(HttpStatusCode.OK)));
    var row = await api.AddAsync("claude", "Work API", new(ApiKinds.Anthropic, WorkspaceId: "wrkspc_1"), "sk-ant-secret-123456");
    Assert.True(row.SignedIn); Assert.Equal(AccountAuthentication.ApiKey, row.Authentication);
    Assert.DoesNotContain("sk-ant-secret", File.ReadAllText(ApiAccountFiles.PathFor(root, row.HomeId)));
    Assert.True((await accounts.RefreshAsync(row.Id)).SignedIn); Assert.Empty(provider.Calls);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await accounts.SignInAsync(row.Id, root.DirectoryPath));
    Assert.Equal("claude-opus-5-5", (await accounts.ModelsAsync(row.Id)).Models[0].Id);
    Assert.Equal("Valid", ApiAccountService.Status(await api.CheckAsync(row.Id)));
    var env = ApiAccountEnvironment.Build("claude", api.Read(row.Id)!, "sk-ant-secret-123456");
    Assert.Equal("sk-ant-secret-123456", env.Variables["ANTHROPIC_API_KEY"]); Assert.Equal("anthropic-workspace-id: wrkspc_1", env.Variables["ANTHROPIC_CUSTOM_HEADERS"]);
    await Assert.ThrowsAsync<ArgumentException>(async () => await api.AddAsync("claude", "x sk-ant-secret-123456", new(ApiKinds.Anthropic), "sk-ant-secret-123456"));
    await api.RemoveAsync(row.Id, _ => false);
    Assert.DoesNotContain(accounts.List(), a => a.Id == row.Id); Assert.False(File.Exists(ApiAccountFiles.PathFor(root, row.HomeId)));
  }
  [Theory]
  [InlineData(HttpStatusCode.Unauthorized, "Invalid key")]
  [InlineData(HttpStatusCode.Forbidden, "No access")]
  [InlineData(HttpStatusCode.InternalServerError, "Couldn’t check")]
  public async Task CheckKeyTellsInvalidNoAccessAndUnavailableApartAndKeepsTheKey(HttpStatusCode code, string expected)
  {
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]);
    var api = new ApiAccountService(accounts, new AccountCredentials(new TestSecretStore(), root), root, new HttpClient(new Answer(code)));
    var row = await api.AddAsync("codex", "OpenAI", new(ApiKinds.OpenAi), "sk-proj-abcdefgh");
    Assert.StartsWith(expected, ApiAccountService.Status(await api.CheckAsync(row.Id)));
    Assert.NotNull(api.Read(row.Id)!.CredentialReference); Assert.True(accounts.Get(row.Id).SignedIn);
  }
  [Fact] public void CodexCompatibleServerUsesItsOwnProviderAndLocalNeedsNoKey()
  {
    var local = ApiAccountEnvironment.Build("codex", new(ApiKinds.CompatibleLocal, "http://127.0.0.1:1234/v1"), null);
    Assert.Empty(local.Variables); Assert.Contains("model_provider=\"terminaldeck\"", local.Arguments);
    Assert.Throws<ArgumentException>(() => ApiKinds.Validate("codex", new(ApiKinds.Compatible, "http://example.com")));
    Assert.Throws<ArgumentException>(() => ApiKinds.Validate("claude", new(ApiKinds.OpenAi)));
  }
  [Fact] public async Task AccountsGetDistinctColoursAndPlansAreKept()
  {
    var provider = new FakeAccountProvider("claude"); var accounts = new AccountService(new MemoryState<AccountState>(), [provider]);
    var a = await accounts.CreateAsync("claude", "A"); var b = await accounts.CreateAsync("claude", "B");
    Assert.NotEqual(a.Color, b.Color);
    await accounts.SetColorAsync(a.Id, "pink"); Assert.Equal("pink", accounts.Get(a.Id).Color);
    await Assert.ThrowsAsync<ArgumentException>(async () => await accounts.SetColorAsync(a.Id, "#ff0000"));
    provider.Statuses[a.Id] = new(true, "a@example.test", "max");
    Assert.Equal("max", (await accounts.RefreshAsync(a.Id)).Plan);
    Assert.Equal("claude-opus-5-5", accounts.InstantModels("claude", b.Id).Models[0].Id);
  }
  [Fact] public void BulkSwitchKeepsIndividuallySetSessionsUnlessAsked()
  {
    var rows = new[] { new RunningAiSession("1", "A", "chat", "claude", "old", null, null, false), new RunningAiSession("2", "B", "terminal", "claude", "old", null, null, true), new RunningAiSession("3", "C", "chat", "claude", "new", null, null, false) };
    var plan = BulkSwitch.Plan(rows, "claude", _ => "new", includeIndividual: false);
    Assert.Equal([BulkSwitchAction.Switch, BulkSwitchAction.KeptIndividual, BulkSwitchAction.Already], plan.Select(r => r.Action));
    Assert.Equal(BulkSwitchAction.Switch, BulkSwitch.Plan(rows, "claude", _ => "new", true)[1].Action);
    Assert.Equal("All already use their assigned account.", BulkSwitch.Summary(BulkSwitch.Plan([rows[2]], "claude", _ => "new", false)));
  }
  [Fact] public void NewToolsAreInTheCatalogueAndChangesAsk()
  {
    var catalogue = TerminalDeck.Core.Mcp.McpCatalogue.Load().ToDictionary(s => s.Id);
    foreach (var spec in AccountMcp.Specs) Assert.True(catalogue.ContainsKey(spec.Id));
    Assert.Equal(TerminalDeck.Core.Mcp.McpTier.Read, TerminalDeck.Core.Mcp.McpCatalogue.EffectiveTier(catalogue["accounts.api"], JsonSerializer.SerializeToElement(new { action = "read" })));
    Assert.Equal(TerminalDeck.Core.Mcp.McpTier.Alter, TerminalDeck.Core.Mcp.McpCatalogue.EffectiveTier(catalogue["accounts.api"], JsonSerializer.SerializeToElement(new { action = "add" })));
    Assert.Equal(TerminalDeck.Core.Mcp.McpTier.Read, TerminalDeck.Core.Mcp.McpCatalogue.EffectiveTier(catalogue["sessions.new_choices"], JsonSerializer.SerializeToElement(new { })));
    Assert.Equal(TerminalDeck.Core.Mcp.McpTier.Alter, TerminalDeck.Core.Mcp.McpCatalogue.EffectiveTier(catalogue["settings.launch_models"], JsonSerializer.SerializeToElement(new { action = "set" })));
  }
  private sealed class Answer(HttpStatusCode code) : HttpMessageHandler
  {
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
      Assert.DoesNotContain("secret", request.RequestUri!.ToString());
      return Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent("{\"error\":{\"message\":\"API key expired\"}}") });
    }
  }
}
