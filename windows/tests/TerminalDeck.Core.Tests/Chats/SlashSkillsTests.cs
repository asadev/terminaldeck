using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Tasks;

namespace TerminalDeck.Core.Tests.Chats;

// Umer, 30 Oct: "/wrap and /catchup and many skills" were missing in the new app.
public sealed class SlashSkillsTests : IDisposable
{
  private readonly string scratch = Directory.CreateTempSubdirectory("td-slash-").FullName;
  public void Dispose() { try { Directory.Delete(scratch, true); } catch (IOException) { } }

  private static Project ILoop => new("iloop", "iLoop", ["C:/Users/admin/Claude-iloop", "C:/Users/admin/Projects/imzacrm"]);

  [Fact]
  public void ProjectSessionsStartInTheHomeFolderAndOpenTheOtherFolders()
  {
    var home = ProjectStartFolders.Choose(ILoop, "C:/Users/admin/Claude-iloop");
    Assert.Equal("C:/Users/admin/Claude-iloop", home.Folder); Assert.Null(home.AskedFolder);
    Assert.Equal(["C:/Users/admin/Projects/imzacrm"], home.ExtraFolders);
    var code = ProjectStartFolders.Choose(ILoop, "C:/Users/admin/Projects/imzacrm/src");
    Assert.Equal("C:/Users/admin/Claude-iloop", code.Folder); Assert.Equal("C:/Users/admin/Projects/imzacrm/src", code.AskedFolder);
    Assert.Equal(["C:/Users/admin/Projects/imzacrm"], code.ExtraFolders);
    // A task's own workspace stays isolated and gets the home folder as extra access.
    var workspace = ProjectStartFolders.Choose(ILoop, "C:/Users/admin/Projects/imzacrm/.terminaldeck-workspaces/abc");
    Assert.Equal("C:/Users/admin/Projects/imzacrm/.terminaldeck-workspaces/abc", workspace.Folder);
    Assert.Equal(["C:/Users/admin/Claude-iloop"], workspace.ExtraFolders);
    var independent = ProjectStartFolders.Choose(ProjectIdentity.Independent, "C:/Elsewhere");
    Assert.Equal("C:/Elsewhere", independent.Folder); Assert.Empty(independent.ExtraFolders);
    Assert.Equal(["C:/Users/admin/Projects/imzacrm"], ProjectStartFolders.ExtraFolders([ProjectIdentity.Independent, ILoop], "C:\\Users\\admin\\Claude-iloop"));
    Assert.Empty(ProjectStartFolders.ExtraFolders([ILoop], "C:/Users/admin/Downloads"));
  }

  [Fact]
  public void ExtraFoldersReadTheSavedProjectsWithoutTheProjectService()
  {
    var root = AppDataRoot.Explicit(Path.Combine(scratch, "data"));
    Assert.Empty(ProjectStartFolders.ExtraFolders(root, "C:/Users/admin/Claude-iloop"));
    new JsonStateStore<ProjectState>(root, "projects").Save(new(1, [ProjectIdentity.Independent, ILoop], null, []));
    Assert.Equal(["C:/Users/admin/Projects/imzacrm"], ProjectStartFolders.ExtraFolders(root, "C:/Users/admin/Claude-iloop"));
  }

  private sealed class Instructions : IAgentInstructions
  { public string Save(string id, string text) => throw new NotSupportedException(); public string Read(string path) => ""; }
  private sealed class ClaudeProvider : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fixture@invalid.test"));
    public ValueTask SignInAsync(AccountProfile a, string folder, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask SignOutAsync(AccountProfile a, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile a, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }

  [Theory]
  [InlineData("chat")]
  [InlineData("terminal")]
  public async Task AgentStartsInTheHomeFolderEvenWhenAskedForTheCodeFolder(string mode)
  {
    var projects = new ProjectService(new MemoryStore<ProjectState>(), new TaskFolders());
    projects.Save(new("iloop", "iLoop", ["C:/Users/admin/Claude-iloop", "C:/Users/admin/Projects/imzacrm"]));
    var accounts = new AccountService(new MemoryStore<AccountState>(), [new ClaudeProvider()]);
    var account = await accounts.CreateAsync("claude", "Sample"); await accounts.RefreshAsync(account.Id); await accounts.SetDefaultAsync("claude", account.Id);
    var plans = new List<AgentLaunchPlan>();
    var agents = new AgentService(new MemoryStore<AgentState>(), projects, new Instructions(), accounts,
      new DelegateAgentSessionGateway((plan, _) => { plans.Add(plan); return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); }));
    agents.Save(new("iloop-lead", "Captain", "claude", ProjectId: "iloop", Seat: "lead", AccountId: account.Id));
    await agents.StartAsync(new("iloop-lead", Mode: mode));
    await agents.StartAsync(new("iloop-lead", Folder: "C:/Users/admin/Projects/imzacrm", Mode: mode, Job: "Fix the login page."));
    await agents.StartAsync(new(null, ProjectId: "iloop", Folder: "C:/Users/admin/Projects/imzacrm", Provider: "claude", AccountId: account.Id, Mode: mode));
    Assert.All(plans, p => Assert.Equal("C:/Users/admin/Claude-iloop", p.Folder));
    Assert.DoesNotContain("Work folder", plans[0].Instructions); Assert.NotEmpty(plans[0].Instructions);
    Assert.Contains("Work folder for this job: C:/Users/admin/Projects/imzacrm", plans[1].Instructions);
    Assert.Equal("", plans[2].Instructions); // a plain (no agent, no job) start gains no first message
  }

  [Fact]
  public void SlashMenuListsTeamSkillsCommandsAndTheAisOwnList()
  {
    var project = Directory.CreateDirectory(Path.Combine(scratch, "Claude-iloop")).FullName;
    var code = Directory.CreateDirectory(Path.Combine(scratch, "imzacrm")).FullName;
    var user = Directory.CreateDirectory(Path.Combine(scratch, "dot-claude")).FullName;
    Write(Path.Combine(project, ".claude", "skills", "wrap", "SKILL.md"), "---\nname: wrap\ndescription: Save the session and hand over\n---\n# Wrap\n");
    Write(Path.Combine(project, ".claude", "skills", "catchup", "SKILL.md"), "---\ndescription: >\n  Load recent context\n  and carry-over\n---\n");
    Write(Path.Combine(project, ".claude", "commands", "deploy.md"), "---\nargument-hint: <lane>\n---\nDeploy a lane to staging\n");
    Write(Path.Combine(project, ".claude", "commands", "lanes", "prune-lanes.md"), "# Prune finished lanes\n");
    Write(Path.Combine(code, ".claude", "skills", "staging-e2e", "SKILL.md"), "---\nname: staging-e2e\ndescription: Run staging end-to-end\n---\n");
    Write(Path.Combine(code, ".claude", "commands", "not-loaded.md"), "Commands in extra folders are not loaded\n");
    Write(Path.Combine(user, "skills", "deep-research", "SKILL.md"), "---\nname: deep-research\ndescription: \"Proper research\"\n---\n");
    var reported = JsonSerializer.SerializeToElement(new { slash_commands = new[] { "compact", "wrap", "theme", "model", "stripe:test-cards" } });

    var rows = ChatSlashCommands.Catalogue("claude", reported, project, [code], user);
    var names = rows.Select(r => r.Name).ToArray();
    Assert.Equal(["catchup", "wrap", "deploy", "prune-lanes", "staging-e2e", "deep-research", "compact", "model", "stripe:test-cards"], names);
    Assert.Equal("Save the session and hand over", rows.Single(r => r.Name == "wrap").Description);
    Assert.Equal("Load recent context and carry-over", rows.Single(r => r.Name == "catchup").Description);
    Assert.Equal("<lane>", rows.Single(r => r.Name == "deploy").ArgumentHint);
    Assert.Equal("Deploy a lane to staging", rows.Single(r => r.Name == "deploy").Description);
    Assert.Equal("Prune finished lanes", rows.Single(r => r.Name == "prune-lanes").Description);
    Assert.Equal("Proper research", rows.Single(r => r.Name == "deep-research").Description);
    Assert.Equal("Summarise the conversation to free context", rows.Single(r => r.Name == "compact").Description);
    Assert.Equal("model", rows.Single(r => r.Name == "model").Control);
    Assert.DoesNotContain("theme", names); Assert.DoesNotContain("not-loaded", names);
    // Codex and Gemini get only what they report.
    Assert.Equal(["compact", "wrap", "model", "stripe:test-cards"], ChatSlashCommands.Catalogue("codex", reported, project, [], user).Select(r => r.Name));
  }

  [Fact]
  public void TypingFiltersExactFirstAndPickingIsReadyToRun()
  {
    ChatSlashCommand[] rows = [new("review-round", "Run a review round"), new("wrap", "Save and hand over"), new("catchup", "Load recent context"), new("deploy", "Deploy", "<lane>")];
    Assert.Null(ChatSlashCommands.Query("hello /wrap")); Assert.Null(ChatSlashCommands.Query("/wrap now")); Assert.Equal("", ChatSlashCommands.Query("/"));
    Assert.Equal(4, ChatSlashCommands.Matches(rows, "").Count);
    Assert.Equal(["wrap"], ChatSlashCommands.Matches(rows, "wr").Select(r => r.Name));
    Assert.Equal(["review-round", "wrap"], ChatSlashCommands.Matches(rows, "r").Select(r => r.Name).Take(2));
    Assert.Equal(["catchup"], ChatSlashCommands.Matches(rows, "context").Select(r => r.Name));
    Assert.Equal("/wrap", ChatSlashCommands.Text(rows[1])); Assert.Equal("/deploy ", ChatSlashCommands.Text(rows[3]));
  }

  private static void Write(string path, string text) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, text); }
}
