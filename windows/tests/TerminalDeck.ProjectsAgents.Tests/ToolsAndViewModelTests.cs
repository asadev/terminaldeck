using System.Text.Json;
using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.ProjectsAgents.Tests;

public sealed class ToolsAndViewModelTests
{
  private static JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);
  private static McpCallContext Context(string[]? resources = null, McpTier[]? tiers = null, AiPermissionMode mode = AiPermissionMode.Ask, Func<CancellationToken, ValueTask>? current = null) =>
    new(new("example-caller", null, null, true, mode, ProjectsAgentsMcp.Specs.Select(s => s.Id).ToArray(), tiers ?? Enum.GetValues<McpTier>(), resources ?? ["*"], DateTimeOffset.UtcNow.AddMinutes(5)),
      current ?? (_ => ValueTask.CompletedTask), _ => { });
  [Fact] public async Task AgentAndTemplateLimitsAreExposedWithoutInventedCeilings()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    await tools.CallAsync("agents.edit_profile", Context(), Args(new { id = a.Id, fields = new { maxConcurrentTasks = 20 } }), default); Assert.Equal(20, f.Agents.Get(a.Id).MaxConcurrentTasks);
    await tools.CallAsync("agents.edit_profile", Context(), Args(new { id = a.Id, fields = new { maxConcurrentTasks = (int?)null } }), default); Assert.Null(f.Agents.Get(a.Id).MaxConcurrentTasks);
    await tools.CallAsync("memory.template.save", Context(), Args(new { category = "agent", handsPerSeat = 0, handsPerProject = 100 }), default);
    Assert.Equal(0, f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent).MaxHandsPerSeat); Assert.Equal(100, f.Agents.Templates().Single(t => t.Category == AgentCategory.Agent).MaxHandsPerProject);
  }
  [Fact] public async Task StatusChangesUseTheExistingGuardedProfileTool()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent();
    var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    await tools.CallAsync("tasks.agents", Context(), Args(new { @do = "save", agent = new { id = a.Id, status = "paused" } }), default);
    Assert.Equal(SavedAgentStatus.Paused, f.Agents.Get(a.Id).Status);
    await tools.CallAsync("tasks.agents", Context(), Args(new { @do = "save", agent = new { id = a.Id, status = "archived" } }), default);
    using var model = new AgentsViewModel(f.Agents, f.Projects);
    Assert.Empty(model.Filter()); Assert.Equal(a.Id, Assert.Single(model.Filter(archived: true)).Id);
    await tools.CallAsync("tasks.agents", Context(), Args(new { @do = "save", agent = new { id = a.Id, status = "active" } }), default);
    Assert.Equal(a.Id, Assert.Single(model.Filter()).Id);
  }
  [Fact] public async Task DuplicateRequiresMemoryAccessBeforeCreatingAnything()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("agents.duplicate", Context(resources: ["agents:*", "projects:sample", "settings:agents"]), Args(new { id = a.Id }), default)); Assert.Single(f.Agents.List());
    await tools.CallAsync("agents.duplicate", Context(), Args(new { id = a.Id, name = "Copied reviewer" }), default); Assert.Equal(2, f.Agents.List().Count);
  }
  [Fact] public async Task FolderCreationToolIsGuardedAndDoesNotRegisterAProject()
  {
    using var f = await Fixture.ReadyAsync(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []); var count = f.Projects.List().Count;
    await tools.CallAsync("projects.create_folder", Context(), Args(new { parent = f.Home, name = "new-folder" }), default);
    Assert.True(Directory.Exists(Path.Combine(f.Home, "new-folder"))); Assert.Equal(count, f.Projects.List().Count);
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("projects.create_folder", Context(tiers: [McpTier.Read]), Args(new { parent = f.Home, name = "refused" }), default));
    Assert.False(Directory.Exists(Path.Combine(f.Home, "refused")));
  }
  [Fact] public void ContractNamesWireNamesAndTiersMatchTheMacContribution()
  {
    var specs = ProjectsAgentsMcp.Specs; Assert.Equal(38, specs.Count); Assert.Equal(McpTier.Read, specs.Single(s => s.Id == "memory.card.read").Tier); Assert.Equal(specs.Count, specs.Select(s => s.Id).Distinct().Count());
    foreach (var spec in specs) Assert.Equal(spec.Id.Replace('.', '_'), spec.Wire);
    Assert.Equal(McpTier.Read, specs.Single(s => s.Id == "agents.directory").Tier); Assert.Equal(McpTier.Alter, specs.Single(s => s.Id == "project_registry.save").Tier);
    Assert.Equal(McpTier.Act, specs.Single(s => s.Id == "agents.add_hand").Tier); Assert.Equal(McpTier.Alter, ProjectsAgentsMcp.Tier(specs.Single(s => s.Id == "tasks.agents"), Args(new { @do = "save" })));
  }
  // CAPTEST S9: a session saved to Hoot's desk (no seat named) and had no way to read its own card back.
  [Fact] public async Task SessionSavesAndReadsItsOwnSeatCardWithoutNamingIt()
  {
    using var f = await Fixture.ReadyAsync(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    const string seat = "role:sample/tester";
    McpCallContext Seat() => new(new("chat:x", "x", null, true, AiPermissionMode.Ask, ProjectsAgentsMcp.Specs.Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(),
      ["memory:" + seat, "projects:sample"], DateTimeOffset.UtcNow.AddMinutes(5), SeatId: seat), _ => ValueTask.CompletedTask, _ => { });
    await tools.CallAsync("memory.card.save", Seat(), Args(new { text = "headlines.md is a CAPTEST fixture" }), default);
    var read = await tools.CallAsync("memory.card.read", Seat(), Args(new { }), default);
    Assert.Equal(seat, read.GetProperty("seat").GetString()); Assert.Contains("CAPTEST fixture", read.GetProperty("card").GetString());
    Assert.Equal("headlines.md is a CAPTEST fixture", read.GetProperty("thisSeatsOwn").GetString());
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("memory.card.read", Seat(), Args(new { seat = "hoot" }), default));
  }
  [Fact] public void NullableContractArgumentsAndExtraFieldsAreChecked()
  {
    var spec = ProjectsAgentsMcp.Specs.Single(s => s.Id == "agents.set_reports_to"); ProjectAgentSchema.Validate(spec.InputSchema, Args(new { id = "example", reportsTo = (string?)null }));
    Assert.Throws<McpRefusal>(() => ProjectAgentSchema.Validate(spec.InputSchema, Args(new { id = "example", reportsTo = 5 })));
    Assert.Throws<McpRefusal>(() => ProjectAgentSchema.Validate(spec.InputSchema, Args(new { id = "example", reportsTo = "@hoot", unexpected = true })));
  }
  [Fact] public async Task ReadToolsFilterProjectsAndAgentsByCurrentResources()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var hidden = f.Agent("private");
    var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => [], f.Accounts);
    var c = Context(["projects:sample", "agents:" + a.Id]);
    var projects = await tools.CallAsync("project_registry.list", c, Args(new { }), default); Assert.Single(projects.GetProperty("projects").EnumerateArray());
    var directory = await tools.CallAsync("agents.directory", c, Args(new { }), default); Assert.Equal(a.Id, Assert.Single(directory.GetProperty("agents").EnumerateArray()).GetProperty("id").GetString());
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("agents.profile", c, Args(new { id = hidden.Id }), default));
  }
  [Fact] public async Task ReadOnlyAndPlanCallersCannotChangeProfiles()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("agents.set_icon", Context(tiers: [McpTier.Read]), Args(new { id = a.Id, icon = "emoji:🙂" }), default));
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("agents.set_icon", Context(mode: AiPermissionMode.Plan), Args(new { id = a.Id, icon = "emoji:🙂" }), default)); Assert.Equal("person", f.Agents.Get(a.Id).Icon);
  }
  [Fact] public async Task PermissionLossBeforeWriteKeepsStateUnchanged()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    var c = Context(current: _ => throw new McpRefusal("Permission changed."));
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("agents.set_reports_to", c, Args(new { id = a.Id, reportsTo = "@hoot" }), default)); Assert.Null(f.Agents.Get(a.Id).ReportsTo);
  }
  [Fact] public async Task ProjectSettingsCannotEscapeTheirProjectOrChangeAnotherAccount()
  {
    using var f = await Fixture.ReadyAsync(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => [], f.Accounts);
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("project_settings.set", Context(["projects:sample"]), Args(new { projectId = "independent", values = new { about = "Changed" } }), default));
    var account = Assert.Single(f.Accounts.List("codex"));
    await Assert.ThrowsAsync<McpRefusal>(async () => await tools.CallAsync("project_settings.set", Context(["projects:sample"]), Args(new { projectId = "sample", values = new { whoUsesWhat = new[] { new { use = "chats", provider = "codex", accountId = account.Id } } } }), default));
    Assert.Empty(f.Projects.Get("sample").Preferences.WhoUsesWhat);
  }
  [Fact] public async Task DoorRegistrationIsAllOrNothingWhenCentralContractsAreMissing()
  {
    using var f = await Fixture.ReadyAsync(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    var broker = new CountingBroker(); var door = new McpDoor(broker); var c = door.RegisterCaller(Context().Grant, (_, _, _, _, _) => ValueTask.FromResult(true));
    var expected = tools.Contributions().Count;
    try { tools.Register(door); Assert.Equal(expected, door.List(c.Id).Count); }
    catch (InvalidOperationException) { Assert.Empty(door.List(c.Id)); }
    Assert.Equal(0, broker.Calls);
  }
  [Fact] public async Task AgentLaunchToolRechecksAccountsFoldersAndCurrentPermission()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => [], f.Accounts);
    var account = Assert.Single(f.Accounts.List("codex")); var checks = 0;
    var c = Context(["agents:" + a.Id, "projects:sample", "folders:" + f.Home, "accounts:" + account.Id], current: _ =>
    {
      if (++checks > 1) throw new McpRefusal("Permission changed."); return ValueTask.CompletedTask;
    });
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await tools.StartAsync(new(a.Id), c, default)); Assert.Empty(f.Gateway.Plans); Assert.True(checks > 1);
  }
  [Fact] public async Task SavedProfileReadDoesNotIncludeInstructionContents()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); f.Agents.SaveInstructions(a.Id, "EXAMPLE_PRIVATE_INSTRUCTIONS");
    var tools = new ProjectsAgentsMcp(f.Projects, f.Agents, new LocalProjectFolders(f.Root), () => []);
    var result = await tools.CallAsync("agents.profile", Context(), Args(new { id = a.Id }), default); Assert.DoesNotContain("EXAMPLE_PRIVATE_INSTRUCTIONS", result.GetRawText());
  }
  [Fact] public async Task ViewModelsDrillIntoTheSameProjectCountsAndSavedProfiles()
  {
    using var f = await Fixture.ReadyAsync(); var a = f.Agent(); var rows = new[] { new ProjectSession(Guid.NewGuid().ToString(), "One", "codex", f.Home, "Running"), new(Guid.NewGuid().ToString(), "Two", "claude", f.Home, "Running") };
    using var projects = new ProjectsViewModel(f.Projects, f.Agents, () => rows, f.Accounts); using var agents = new AgentsViewModel(f.Agents, f.Projects, f.Accounts);
    Assert.Equal(2, projects.SessionsFor("sample").Count); Assert.Single(projects.AgentsFor("sample"));
    projects.SelectedId = "sample"; agents.SelectedId = a.Id; Assert.Equal("Sample project", projects.Selected?.Name); Assert.Equal(a.Name, agents.Selected?.Name); Assert.Empty(agents.Filter("not here"));
  }
  [Fact] public async Task PendingFeedbackPreventsDuplicateWritesAndErrorsStayVisible()
  {
    var vm = new ExampleOperation(); var entered = new TaskCompletionSource(); var release = new TaskCompletionSource(); var writes = 0;
    var first = vm.RunAsync(async () => { entered.SetResult(); await release.Task; writes++; }); await entered.Task;
    Assert.True(vm.IsBusy); Assert.Contains("Saving", vm.Message); Assert.False(await vm.RunAsync(() => writes++));
    release.SetResult(); Assert.True(await first); Assert.Equal(1, writes);
    Assert.False(await vm.RunAsync(() => throw new ArgumentException("Choose a home folder."))); Assert.True(vm.IsError); Assert.Equal("Choose a home folder.", vm.Message);
  }
  private sealed class ExampleOperation : ProjectAgentViewModel;
  private sealed class CountingBroker : IMcpPermissionBroker
  {
    public int Calls { get; private set; }
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct)
    { Calls++; return ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false)); }
  }
}
