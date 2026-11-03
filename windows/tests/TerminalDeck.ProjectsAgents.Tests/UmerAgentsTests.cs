using System.Text.Json;
using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.ProjectsAgents.Tests;

// Umer's first use (30 Oct): projects without logos and an Agents page with far fewer controls than the Mac.
public sealed class UmerAgentsTests
{
  private static JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);
  private static McpCallContext Context() =>
    new(new("example-caller", null, null, true, AiPermissionMode.Ask, ProjectsAgentsMcp.Specs.Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddMinutes(5)),
      _ => ValueTask.CompletedTask, _ => { });
  private static void Touch(string path, string text = "x") { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, text); }

  [Fact] public void LogoFinderFollowsTheMacOrderAndAddsWindowsSources()
  {
    using var f = new Fixture(); var h = f.Home;
    Touch(Path.Combine(h, "public", "apple-touch-icon.png")); Touch(Path.Combine(h, "public", "favicon.ico")); Touch(Path.Combine(h, "public", "icon.svg"));
    Touch(Path.Combine(h, "public", "manifest.json"), """{"icons":[{"src":"/pwa-64.png","sizes":"64x64"},{"src":"/pwa-512.png","sizes":"512x512"}]}"""); Touch(Path.Combine(h, "public", "pwa-512.png")); Touch(Path.Combine(h, "public", "pwa-64.png"));
    Touch(Path.Combine(h, "package.json"), """{"name":"x","build":{"icon":"art/app.png"}}"""); Touch(Path.Combine(h, "art", "app.png"));
    Touch(Path.Combine(h, "src", "Desk", "Desk.csproj"), "<Project><PropertyGroup><ApplicationIcon>Assets\\desk.ico</ApplicationIcon></PropertyGroup></Project>"); Touch(Path.Combine(h, "src", "Desk", "Assets", "desk.ico"));
    Touch(Path.Combine(h, "Mac", "Assets.xcassets", "AppIcon.appiconset", "small.png"), "a"); Touch(Path.Combine(h, "Mac", "Assets.xcassets", "AppIcon.appiconset", "large.png"), new string('a', 50));
    Touch(Path.Combine(h, "android", "res", "mipmap-hdpi", "ic_launcher.png")); Touch(Path.Combine(h, "android", "res", "mipmap-xxxhdpi", "ic_launcher.png"));
    Touch(Path.Combine(h, "notes", "scratch", "photos", "deep", "logo.png")); Touch(Path.Combine(h, "node_modules", "pkg", "logo.png")); Touch(Path.Combine(h, "screenshot.png"));
    var found = ProjectLogoSuggestions.Find(h).Select(p => Path.GetRelativePath(h, p).Replace('\\', '/')).ToArray();
    Assert.Equal("public/apple-touch-icon.png", found[0]);
    Assert.Contains("public/favicon.ico", found); Assert.Contains("public/pwa-512.png", found); Assert.DoesNotContain("public/pwa-64.png", found);
    Assert.Contains("art/app.png", found); Assert.Contains("src/Desk/Assets/desk.ico", found);
    Assert.Contains("Mac/Assets.xcassets/AppIcon.appiconset/large.png", found); Assert.Contains("android/res/mipmap-xxxhdpi/ic_launcher.png", found);
    Assert.DoesNotContain(found, p => p.Contains("node_modules") || p.Contains("deep") || p.EndsWith("screenshot.png") || p.Contains("mipmap-hdpi"));
    Assert.True(found.Length <= ProjectLogoSuggestions.Limit);
  }
  [Fact] public void LogoFinderSearchesEveryProjectFolderAndNeverFollowsLinks()
  {
    using var f = new Fixture(); var team = Path.Combine(f.Directory, "team"); Directory.CreateDirectory(team);
    var external = Path.Combine(f.Directory, "elsewhere"); Touch(Path.Combine(external, "favicon.ico")); Directory.CreateSymbolicLink(Path.Combine(team, "public"), external);
    Touch(Path.Combine(f.Home, "public", "favicon.ico"));
    var found = ProjectLogoSuggestions.Find([team, f.Home]);
    Assert.Equal(Path.Combine(f.Home, "public", "favicon.ico"), Assert.Single(found));
  }
  [Fact] public void AutomaticLogoUsesTheFirstUsablePictureAndARemovedLogoStaysRemoved()
  {
    using var f = new Fixture(); Touch(Path.Combine(f.Home, "logo.svg")); Touch(Path.Combine(f.Home, "public", "favicon.ico"));
    f.Projects.Save(new("crm", "CRM", [f.Home]));
    Assert.EndsWith("favicon.ico", ProjectLogoAuto.Fill(f.Projects, "crm"));
    Assert.Equal("crm-picture.png", f.Projects.Get("crm").Logo);
    Assert.Null(ProjectLogoAuto.Fill(f.Projects, "crm"));
    f.Projects.SetPicture("crm", null); Assert.True(f.Projects.Get("crm").Preferences.Flag(ProjectLogoAuto.OffKey));
    Assert.Null(ProjectLogoAuto.Fill(f.Projects, "crm")); Assert.Equal("", f.ReloadProjects().Get("crm").Logo);
    f.Projects.SetPicture("crm", Path.Combine(f.Home, "public", "favicon.ico")); Assert.False(f.Projects.Get("crm").Preferences.Flag(ProjectLogoAuto.OffKey));
    Assert.Equal(0, ProjectLogoAuto.FillAll(f.Projects));
    Assert.Throws<ArgumentException>(() => f.Projects.SetPicture(ProjectIdentity.IndependentId, Path.Combine(f.Home, "public", "favicon.ico")));
  }
  [Fact] public async Task TheProjectsModelGivesLogosInTheBackground()
  {
    using var f = new Fixture(); Touch(Path.Combine(f.Home, "public", "apple-touch-icon.png"));
    f.Projects.Save(new("site", "Site", [f.Home]));
    using var model = new ProjectsViewModel(f.Projects, f.Agents, () => []);
    await model.LogoScan!; Assert.Equal("site-picture.png", f.Projects.Get("site").Logo);
  }
  [Fact] public async Task AgentSettingsReachTheLaunchAndSurviveReload()
  {
    using var f = await Fixture.ReadyAsync(); var work = Path.Combine(f.Home, "api"); Directory.CreateDirectory(work);
    f.Projects.PatchSettings("sample", new Dictionary<string, JsonElement> { ["linkedServers"] = JsonSerializer.SerializeToElement("prod-1, staging") });
    var a = f.Agent();
    var saved = f.Agents.Save(a with { Options = new(PermissionMode: "plan", WorkingFolder: work, ToolsPreferred: ["rg"], ToolsAvoided: ["curl"]) }, a);
    await f.Agents.StartAsync(new(saved.Id, Mode: "terminal"));
    var plan = f.Gateway.Plans.Single();
    Assert.Equal(TerminalDeck.Core.Mcp.AiPermissionMode.Plan, plan.Permission); Assert.Equal(ProjectPaths.Normalize(work), plan.Folder);
    Assert.Contains("should use where they fit: rg", plan.Instructions); Assert.Contains("should avoid: curl", plan.Instructions);
    Assert.Contains("Servers linked to this project: prod-1, staging", plan.Instructions); Assert.Contains("Saved skill references", plan.Instructions);
    Assert.Equal("plan", KeeperAgentSessionGateway.Definition(plan).Permission);
    var reloaded = f.ReloadAgents().Get(saved.Id).Settings; Assert.Equal("plan", reloaded.PermissionMode); Assert.Equal(["rg"], reloaded.ToolsPreferred.ToArray());
    Assert.Throws<ArgumentException>(() => f.Agents.Save(saved with { Options = saved.Settings with { WorkingFolder = f.Directory } }, f.Agents.Get(saved.Id)));
    Assert.Throws<ArgumentException>(() => f.Agents.Save(saved with { Options = saved.Settings with { PermissionMode = "yolo" } }, f.Agents.Get(saved.Id)));
  }
  [Fact] public async Task ProjectPermissionAppliesWhenTheAgentUsesAppDefaultAndSkillsCanBeTurnedOff()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    f.Projects.PatchSettings("sample", new Dictionary<string, JsonElement> { ["defaultPermission"] = JsonSerializer.SerializeToElement("auto") });
    f.Agents.Save(a with { Options = new(SkillsOff: true) }, a);
    await f.Agents.StartAsync(new(a.Id, Mode: "terminal"));
    var plan = f.Gateway.Plans.Single(); Assert.Equal(TerminalDeck.Core.Mcp.AiPermissionMode.Auto, plan.Permission);
    Assert.DoesNotContain("Saved skill references", plan.Instructions); Assert.Contains("Skills are turned off", plan.Instructions);
  }
  [Fact] public async Task StopEverythingClosesEachLiveHandThroughTheSessionOwner()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    await f.Agents.StartAsync(new(a.Id, Mode: "terminal", Job: "one")); await f.Agents.StartAsync(new(a.Id, Mode: "terminal", Job: "two"));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Agents.StopHandsAsync(a.Id));
    var stopped = new List<string>();
    var gateway = new KeeperAgentSessionGateway((d, _) => throw new InvalidOperationException(), stop: (id, _) => { stopped.Add(id); return ValueTask.CompletedTask; });
    var agents = new AgentService(new TerminalDeck.Core.Storage.JsonStateStore<AgentState>(f.Root, "agents"), f.Projects, new AgentInstructions(f.Root), f.Accounts, gateway);
    Assert.Equal(2, await agents.StopHandsAsync(a.Id)); Assert.Equal(f.Agents.Runs().Select(r => r.SessionId).Order(), stopped.Order());
  }
  [Fact] public void StatusSaysWorkingOnlyWhenASessionIsReallyBusy()
  {
    var agent = new SavedAgent("dev", "Dev", "claude");
    AgentRun Run(string id) => new(id, "dev", "Dev", "claude", "independent", null, 1, "", "chat", AgentRunState.Running, DateTimeOffset.UnixEpoch);
    ProjectSession Row(string id, string status) => new(id, "t", "claude", "/w", status);
    Assert.Equal(AgentActivityState.Ready, AgentActivity.For(agent, [], []).State);
    Assert.Equal(AgentActivityState.Working, AgentActivity.For(agent, [Run("a"), Run("b")], [Row("a", "working"), Row("b", "waiting")]).State);
    Assert.Equal(AgentActivityState.Idle, AgentActivity.For(agent, [Run("a")], [Row("a", "waiting")]).State);
    Assert.Equal(AgentActivityState.Open, AgentActivity.For(agent, [Run("a")], [Row("a", "Running")]).State);
    Assert.Equal(AgentActivityState.Ready, AgentActivity.For(agent, [Run("a")], [Row("a", "ended")]).State);
    Assert.Equal(AgentActivityState.Paused, AgentActivity.For(agent with { Status = SavedAgentStatus.Paused }, [Run("a")], [Row("a", "working")]).State);
  }
  [Fact] public void InstalledSkillsAreReadFromSkillFiles()
  {
    using var f = new Fixture();
    Touch(Path.Combine(f.Home, ".claude", "skills", "deploy", "SKILL.md"), "---\nname: deploy-site\ndescription: \"Ship the site\"\n---\nBody");
    Touch(Path.Combine(f.Home, ".claude", "skills", "plain", "SKILL.md"), "No front matter");
    Directory.CreateDirectory(Path.Combine(f.Home, ".claude", "skills", "empty"));
    var skills = AgentSkills.Find(AgentSkills.Roots([f.Home], home: Path.Combine(f.Directory, "nobody")));
    Assert.Equal(["deploy-site", "plain"], skills.Select(s => s.Name));
    Assert.Equal("Ship the site", skills[0].Description);
  }
  [Fact] public async Task ToolsSaveTheNewSettingsAndReportStatusSkillsAndNotes()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    Touch(Path.Combine(f.Home, ".claude", "skills", "review", "SKILL.md"), "---\nname: review\ndescription: Review code\n---");
    var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    await tools.CallAsync("agents.edit_profile", Context(), Args(new { id = a.Id, fields = new { permissionMode = "ask", toolsAvoided = new[] { "rm" }, skillsOff = true } }), default);
    var s = f.Agents.Get(a.Id).Settings; Assert.Equal("ask", s.PermissionMode); Assert.Equal(["rm"], s.ToolsAvoided.ToArray()); Assert.True(s.SkillsOff);
    var profile = await tools.CallAsync("agents.profile", Context(), Args(new { id = a.Id }), default);
    Assert.Equal("ready", profile.GetProperty("activity").GetProperty("state").GetString()); Assert.Equal("ask", profile.GetProperty("agent").GetProperty("permissionMode").GetString());
    var skills = await tools.CallAsync("agents.skills", Context(), Args(new { agent = a.Id }), default);
    Assert.Contains(skills.GetProperty("installed").EnumerateArray(), k => k.GetProperty("name").GetString() == "review" && k.GetProperty("assigned").GetBoolean());
    await tools.CallAsync("memory.notes.save", Context(), Args(new { seat = f.Agents.SeatOf(a.Id).Key, text = "Learned: run tests first." }), default);
    Assert.Equal("Learned: run tests first.", ((IAgents)f.Agents).SeatMemory(a.Id)!.Notes);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await tools.CallAsync("agents.stop_hands", Context(), Args(new { agent = a.Id }), default));
  }
  [Fact] public async Task DirectoryFiltersByRoleStatusAndShowsVacantSeats()
  {
    using var f = await Fixture.ReadyAsync();
    var lead = f.Agent("captain", "captain"); f.Agent("tester", "tester"); var gone = f.Agent("writer", "writer");
    f.Agents.SetProjectLead("sample", lead.Id);
    f.Agents.Save(f.Agents.Get(gone.Id) with { Status = SavedAgentStatus.Archived }, f.Agents.Get(gone.Id));
    using var model = new AgentsViewModel(f.Agents, f.Projects, f.Accounts);
    Assert.Equal("captain", Assert.Single(model.Filter(role: "lead")).Id);
    Assert.Equal("tester", Assert.Single(model.Filter(role: "role:tester")).Id);
    Assert.Equal(2, model.Filter(state: "Ready").Count); Assert.Empty(model.Filter(state: "Working"));
    Assert.Equal(["tester"], model.Roles());
    Assert.Equal("role:sample/writer", Assert.Single(model.VacantSeats("sample")).Key);
    Assert.Contains("the app's default", model.AccountLine(f.Agents.Get("tester")));
  }
}
