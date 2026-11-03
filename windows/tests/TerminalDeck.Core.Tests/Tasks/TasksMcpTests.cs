using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TasksMcpTests
{
  private sealed class Permissions : IMcpPermissionBroker
  {
    public int Changes;
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest r, CancellationToken ct)
    { Changes++; return ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true)); }
  }
  [Theory]
  [InlineData("tasks.local_change", "detail", McpTier.Alter)]
  [InlineData("tasks.local_change", "create", McpTier.Alter)]
  [InlineData("tasks.local_change", "assign", McpTier.Alter)]
  [InlineData("tasks.local_change", "update", McpTier.Alter)]
  [InlineData("tasks.local_change", "delete", McpTier.Alter)]
  [InlineData("tasks.local_change", "status", McpTier.Act)]
  [InlineData("tasks.local_change", "comment", McpTier.Act)]
  [InlineData("tasks.views", "list", McpTier.Read)]
  [InlineData("tasks.views", "update", McpTier.Alter)]
  [InlineData("tasks.views", "save", McpTier.Alter)]
  [InlineData("tasks.views", "delete", McpTier.Alter)]
  [InlineData("tasks.views", "rename", McpTier.Alter)]
  [InlineData("tasks.views", "select", McpTier.Alter)]
  [InlineData("tasks.views", "revert", McpTier.Alter)]
  [InlineData("tasks.goals", "list", McpTier.Read)]
  [InlineData("tasks.goals", "get", McpTier.Read)]
  [InlineData("tasks.goals", "save", McpTier.Alter)]
  [InlineData("tasks.goals", "delete", McpTier.Alter)]
  public void MixedActionTiersMatchMacTaskPolicy(string id, string action, McpTier expected)
  {
    var spec = TasksMcp.Specs.Single(s => s.Id == id); Assert.Equal(expected, TasksMcp.Tier(spec, TasksMcp.Value(new { @do = action })));
    Assert.Equal(id.Replace('.', '_'), spec.Wire);
  }
  [Fact] public void ContributionRegistersAgainstTheIntegratedCatalogueAndTierRules()
  {
    var f = new TaskFixture(); var tools = new TasksMcp(f.Tasks, f.Projects, "pc", id => f.People.GetValueOrDefault(id));
    var door = new McpDoor(new Permissions());
    tools.Register(door);
    var caller = door.RegisterCaller(new("catalogue-fixture", null, null, true, AiPermissionMode.Ask,
      TasksMcp.Specs.Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    Assert.Contains(door.List(caller.Id), s => s.Id == "tasks.comment");
    Assert.Contains(door.List(caller.Id), s => s.Id == "tasks.reassign");
    Assert.All(tools.Contributions(), t => Assert.False(t.Spec.Id.StartsWith("connected_tasks.", StringComparison.Ordinal)));
  }
  [Fact] public async Task DetailUsesTheExistingPermissionDoorAndIsReadableAfterSave()
  {
    var f = new TaskFixture(); var task = f.Create();
    var permissions = new Permissions(); var door = new McpDoor(permissions);
    var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null); tools.Register(door);
    var caller = door.RegisterCaller(new("details-fixture", null, null, true, AiPermissionMode.Ask,
      ["tasks.local_change", "tasks.get"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "detail", task = task.Id, detail_action = "field", value = "Customer" }));
    Assert.Equal(1, permissions.Changes);
    var result = await door.CallAsync(caller.Id, "tasks.get", TasksMcp.Value(new { task = task.Id }));
    Assert.Equal("Customer", result.GetProperty("task").GetProperty("extras").GetProperty("fields")[0].GetProperty("name").GetString());
  }
  [Fact] public async Task MultiProjectViewsDoNotLeakOrWriteUnrelatedProjectState()
  {
    var f = new TaskFixture(); f.Tasks.SaveView("pc", null, "Private view", new(ProjectIds: ["other"]));
    var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null); var door = new McpDoor(new Permissions()); tools.Register(door);
    var caller = door.RegisterCaller(new("multi-view-fixture", null, null, true, AiPermissionMode.Ask, ["tasks.views"], Enum.GetValues<McpTier>(), ["settings:tasks", "projects:sample"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var list = await door.CallAsync(caller.Id, "tasks.views", TasksMcp.Value(new { @do = "list" })); Assert.Empty(list.GetProperty("tabs").EnumerateArray());
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "tasks.views", TasksMcp.Value(new { @do = "update", state = new { projectIds = new[] { "sample", "other" } } })));
    Assert.True(f.Tasks.Filter("pc").ProjectIds.IsDefaultOrEmpty);
  }
  [Fact] public async Task GoalToolsKeepApprovalAndProjectBoundaries()
  {
    var f = new TaskFixture(); var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null); var broker = new Permissions(); var door = new McpDoor(broker); tools.Register(door);
    var caller = door.RegisterCaller(new("goal-fixture", null, null, true, AiPermissionMode.Ask, ["tasks.goals"], Enum.GetValues<McpTier>(), ["tasks:*", "projects:sample"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var saved = await door.CallAsync(caller.Id, "tasks.goals", TasksMcp.Value(new { @do = "save", title = "Release", projectId = "sample" })); var id = saved.GetProperty("id").GetString();
    var other = f.Tasks.SaveGoal(new("Private", "", "other"), TaskActor.Owner);
    var list = await door.CallAsync(caller.Id, "tasks.goals", TasksMcp.Value(new { @do = "list" })); Assert.Single(list.GetProperty("goals").EnumerateArray());
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "tasks.goals", TasksMcp.Value(new { @do = "get", id = other.Id })));
    await door.CallAsync(caller.Id, "tasks.goals", TasksMcp.Value(new { @do = "delete", id })); Assert.Equal(other.Id, Assert.Single(f.Tasks.Goals()).Id);
    Assert.True(broker.Changes >= 2);
  }
  [Fact] public async Task SavedViewToolsUseTheExistingApprovalDoorAndKeepAllSettings()
  {
    var f = new TaskFixture(); var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null); var broker = new Permissions(); var door = new McpDoor(broker); tools.Register(door);
    var caller = door.RegisterCaller(new("view-fixture", null, null, true, AiPermissionMode.Ask, ["tasks.views"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "tasks.views", TasksMcp.Value(new { @do = "save", name = "Review", state = new { groupBy = "tags", sort = "name", descending = true, due = "week", view = "Calendar", columns = new[] { "due", "created" } } }));
    var view = Assert.Single(f.Tasks.Views("pc")); Assert.Equal("tags", view.State.GroupBy); Assert.True(view.State.Descending); Assert.Equal("Calendar", view.State.View);
    await door.CallAsync(caller.Id, "tasks.views", TasksMcp.Value(new { @do = "select", id = view.Id })); Assert.Equal("week", f.Tasks.Filter("pc").Due);
    await door.CallAsync(caller.Id, "tasks.views", TasksMcp.Value(new { @do = "rename", id = view.Id, name = "Review next" })); Assert.Equal("Review next", Assert.Single(f.Tasks.Views("pc")).Name);
    await door.CallAsync(caller.Id, "tasks.views", TasksMcp.Value(new { @do = "delete", id = view.Id })); Assert.Empty(f.Tasks.Views("pc")); Assert.Equal(4, broker.Changes);
  }
  [Fact] public async Task ReadHandlerFiltersEveryResultAndDoesNotTrustCallerNamedArguments()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Tasks.Create(new("Private task", ProjectId: "other"), TaskActor.Owner);
    var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null); var door = new McpDoor(new Permissions());
    // A registered read supplies a real caller context to this contribution's
    // read handler. Full task-door registration is the integration lane's gate.
    var action = "tasks.local"; var args = TasksMcp.Value(new { @do = "list" });
    door.Register("projects.list", (ctx, _, ct) => tools.CallAsync(action, ctx, args, ct));
    var caller = door.RegisterCaller(new("read-fixture", null, null, true, AiPermissionMode.Ask,
      ["projects.list", "tasks.local"], [McpTier.Read], ["tasks:*", "projects:sample", "folders:C:/Work/Sample"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var result = await door.CallAsync(caller.Id, "projects.list", TasksMcp.Value(new { }));
    Assert.Equal(task.Id, Assert.Single(result.GetProperty("tasks").EnumerateArray()).GetProperty("task").GetString());
    args = TasksMcp.Value(new { @do = "get", task = "missing" });
    await Assert.ThrowsAsync<ArgumentException>(async () => await door.CallAsync(caller.Id, "projects.list", TasksMcp.Value(new { })));
    args = TasksMcp.Value(new { @do = "list", caller = "owner" });
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "projects.list", TasksMcp.Value(new { })));
  }
  [Fact] public async Task HandlerRefusesMutationInPlanModeEvenWhenOuterCallerHasAllTiers()
  {
    var f = new TaskFixture(); var task = f.Create(); var tools = new TasksMcp(f.Tasks, f.Projects, "pc", _ => null); var permissions = new Permissions(); var door = new McpDoor(permissions);
    door.Register("projects.list", (ctx, _, ct) => tools.CallAsync("tasks.local_change", ctx, TasksMcp.Value(new { @do = "status", task = task.Id, status = "Done" }), ct));
    var caller = door.RegisterCaller(new("plan-fixture", null, null, true, AiPermissionMode.Plan,
      ["projects.list", "tasks.local_change"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "projects.list", TasksMcp.Value(new { })));
    Assert.Equal("To-Do", f.Tasks.Get(task.Id).Status); Assert.Equal(0, permissions.Changes);
  }
}
