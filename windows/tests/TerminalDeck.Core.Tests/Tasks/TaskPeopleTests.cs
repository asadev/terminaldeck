using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskPeopleTests
{
  private static TaskFixture Fixture()
  {
    var f = new TaskFixture(); f.People["builder"] = new("builder", "Builder", "agent", null); return f;
  }
  [Fact] public void InvitationsReplacePersonalPrimaryThenAddPeopleWithoutStartingWork()
  {
    var f = Fixture(); var task = f.Create();
    var first = f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    Assert.Equal("reviewer", first.Assignee); Assert.Empty(TaskExtras.Of(first).Participants);
    var shared = f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner);
    Assert.Equal("reviewer", shared.Assignee); Assert.Equal(new[] { "builder" }, TaskExtras.Of(shared).Participants);
    Assert.Equal(task.Status, shared.Status); Assert.Null(shared.CurrentRunId); Assert.Empty(f.Tasks.Runs()); Assert.Empty(f.Runner.Notifications);
    Assert.Equal("assignees", shared.Activity[^1].Kind);
    var again = f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner);
    Assert.Equal(new[] { "builder" }, TaskExtras.Of(again).Participants); Assert.Equal(shared.Revision, again.Revision);
    var copy = f.Open().Get(task.Id); Assert.Equal(shared.Assignee, copy.Assignee); Assert.Equal(TaskExtras.Of(shared).Participants, TaskExtras.Of(copy).Participants);
  }
  [Fact] public void PrimaryAndAdditionalPeopleBothMatchTaskAssigneeFilters()
  {
    var f = Fixture(); var task = f.Create(); f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner);
    Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Assignee: "builder"))).Id);
    Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Assignee: "reviewer"))).Id);
    Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Assignees: ["builder"]))).Id);
    Assert.Empty(f.Tasks.List(new(Assignee: "me")));
    f.Tasks.Detail(task.Id, "share", null, "me", TaskActor.Owner);
    Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Assignee: "me"))).Id);
  }
  [Fact] public void RemovingPrimaryPromotesNextAndLastMainPersonCannotBeRemoved()
  {
    var f = Fixture(); var task = f.Create();
    f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner);
    var promoted = f.Tasks.Detail(task.Id, "unshare", null, "reviewer", TaskActor.Owner);
    Assert.Equal("builder", promoted.Assignee); Assert.Empty(TaskExtras.Of(promoted).Participants);
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Detail(task.Id, "unshare", null, "builder", TaskActor.Owner));
    Assert.Equal(promoted, f.Tasks.Get(task.Id)); Assert.Empty(f.Tasks.Runs());
  }
  [Fact] public async Task ExplicitMainPersonAndExistingAssignmentCannotDuplicateAParticipant()
  {
    var f = Fixture(); var task = f.Create();
    f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    var primary = f.Tasks.Detail(task.Id, "share-primary", null, "builder", TaskActor.Owner);
    Assert.Equal("builder", primary.Assignee); Assert.Equal(new[] { "reviewer" }, TaskExtras.Of(primary).Participants);
    var running = await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner);
    Assert.Equal("reviewer", running.Assignee); Assert.DoesNotContain("reviewer", TaskExtras.Of(running).Participants);
    var count = f.Tasks.Runs().Count; var unchangedStatus = running.Status;
    var shared = f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner);
    Assert.Equal(count, f.Tasks.Runs().Count); Assert.Equal(running.CurrentRunId, shared.CurrentRunId); Assert.Equal(unchangedStatus, shared.Status);
  }
  [Fact] public void UnknownPeopleAndFailedWritesKeepTheWholeLedger()
  {
    var f = Fixture(); var task = f.Create();
    Assert.Throws<ArgumentException>(() => f.Tasks.Detail(task.Id, "share", null, "invented", TaskActor.Owner));
    Assert.Throws<ArgumentException>(() => f.Tasks.Detail(task.Id, "share", null, "none", TaskActor.Owner));
    f.Persistence.Fail = true;
    Assert.Throws<IOException>(() => f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner)); Assert.Equal(task, f.Tasks.Get(task.Id));
  }
  [Theory] [InlineData(1)] [InlineData(2)] [InlineData(3)]
  public void LegacyLedgerMigratesAndRosterSurvivesJsonAndUnrelatedEdits(int version)
  {
    var f = Fixture(); var task = f.Create(); f.Persistence.State = f.Persistence.State! with { Version = version };
    var reopened = f.Open(); Assert.Empty(TaskExtras.Of(reopened.Get(task.Id)).Participants);
    reopened.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner); reopened.Detail(task.Id, "share", null, "builder", TaskActor.Owner);
    Assert.Equal(4, f.Persistence.State!.Version);
    f.Persistence.State = JsonSerializer.Deserialize<TasksState>(JsonSerializer.Serialize(f.Persistence.State));
    var next = f.Open(); next.Status(task.Id, "In Progress", TaskActor.Owner); next.Detail(task.Id, "star", null, null, TaskActor.Owner);
    Assert.Equal("reviewer", next.Get(task.Id).Assignee); Assert.Equal(new[] { "builder" }, TaskExtras.Of(next.Get(task.Id)).Participants);
  }
  [Fact] public void FutureVersionsAndMalformedRostersAreRefusedWithoutWriting()
  {
    var f = Fixture(); var task = f.Create(); var saved = f.Persistence.State!;
    f.Persistence.State = saved with { Version = 5 }; Assert.Throws<IOException>(() => f.Open()); Assert.Equal(5, f.Persistence.State.Version);
    foreach (var ids in new ImmutableArray<string>[] { ["reviewer", "reviewer"], ["me"], ["none"], ["bad\nidentity"] })
    {
      f.Persistence.State = saved with { Tasks = [task with { Extras = new TaskExtras { Participants = ids } }] };
      Assert.Throws<IOException>(() => f.Open()); Assert.Equal(ids, f.Persistence.State.Tasks[0].Extras!.Participants);
    }
  }
  [Fact] public void MissingAdditionalPersonCanBeRemovedButCannotBeInvitedAgain()
  {
    var f = Fixture(); var task = f.Create(); f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner); f.People.Remove("builder");
    var removed = f.Tasks.Detail(task.Id, "unshare", null, "builder", TaskActor.Owner);
    Assert.Equal("reviewer", removed.Assignee); Assert.Empty(TaskExtras.Of(removed).Participants);
    Assert.Contains("builder", removed.Activity[^1].Text); Assert.Empty(f.Tasks.Runs());
    Assert.Throws<ArgumentException>(() => f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner));
    Assert.Throws<ArgumentException>(() => f.Tasks.Detail(task.Id, "share-primary", null, "builder", TaskActor.Owner));
  }
  [Fact] public void MissingPrimaryCanBeRemovedAndPromotesStoredNextPersonButCannotRemoveLastPrimary()
  {
    var f = Fixture(); var task = f.Create(); f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner); f.People.Clear();
    var promoted = f.Tasks.Detail(task.Id, "unshare", null, "reviewer", TaskActor.Owner);
    Assert.Equal("builder", promoted.Assignee); Assert.Empty(TaskExtras.Of(promoted).Participants);
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Detail(task.Id, "unshare", null, "builder", TaskActor.Owner));
    Assert.Equal(promoted, f.Tasks.Get(task.Id)); Assert.Empty(f.Tasks.Runs());
  }
  [Fact] public async Task RemovingMissingMemberNeedsTaskApprovalWithoutTheDeletedProfileGrant()
  {
    var f = Fixture(); var task = f.Create(); f.Tasks.Detail(task.Id, "share", null, "reviewer", TaskActor.Owner);
    f.Tasks.Detail(task.Id, "share", null, "builder", TaskActor.Owner); f.People.Remove("builder");
    var permission = new Permission(); var door = new McpDoor(permission);
    new TasksMcp(f.Tasks, f.Projects, "pc", id => f.People.GetValueOrDefault(id)).Register(door);
    var caller = door.RegisterCaller(new("remove-fixture", null, null, true, AiPermissionMode.Ask, ["tasks.local_change"], Enum.GetValues<McpTier>(),
      ["tasks:" + task.Id, "projects:sample", "folders:C:/Work/Sample"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "detail", task = task.Id, detail_action = "unshare", value = "builder" }));
    Assert.Equal(1, permission.Asked); Assert.Empty(TaskExtras.Of(f.Tasks.Get(task.Id)).Participants); Assert.Empty(f.Tasks.Runs());
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "detail", task = task.Id, detail_action = "share", value = "reviewer" })));
  }
  private sealed class Permission : IMcpPermissionBroker
  {
    public int Asked;
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct)
    { Asked++; return ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true)); }
  }
  [Fact] public async Task SharingToolUsesExistingApprovalAndRosterReadWithoutRunningAnAgent()
  {
    var f = Fixture(); var task = f.Create(); var permission = new Permission(); var door = new McpDoor(permission);
    new TasksMcp(f.Tasks, f.Projects, "pc", id => f.People.GetValueOrDefault(id)).Register(door);
    var caller = door.RegisterCaller(new("share-fixture", null, null, true, AiPermissionMode.Ask, ["tasks.local_change", "tasks.get"], Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "detail", task = task.Id, detail_action = "share", value = "reviewer" }));
    await door.CallAsync(caller.Id, "tasks.local_change", TasksMcp.Value(new { @do = "detail", task = task.Id, detail_action = "share", value = "builder" }));
    Assert.Equal(2, permission.Asked); Assert.Empty(f.Tasks.Runs());
    var read = await door.CallAsync(caller.Id, "tasks.get", TasksMcp.Value(new { task = task.Id }));
    Assert.Equal("reviewer", read.GetProperty("task").GetProperty("assignee").GetString());
    Assert.Equal("builder", read.GetProperty("task").GetProperty("participants")[0].GetString());
  }
}
