using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskReviewFixTests
{
  private sealed class Permissions : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct) =>
      ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true));
  }
  private sealed class Clock : TimeProvider
  {
    public DateTimeOffset Now = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Now;
  }
  private static (McpDoor Door, McpRegistration Caller) Door(TaskFixture f, string[] sessions, Clock? clock = null,
    Func<bool>? current = null, bool hoot = false)
  {
    var door = new McpDoor(new Permissions(), clock);
    var tools = new TasksMcp(f.Tasks, f.Projects, "test-pc", id => f.People.GetValueOrDefault(id));
    door.Register("tasks.comment", (ctx, args, ct) => tools.CallAsync("tasks.comment", ctx, args, ct));
    var caller = door.RegisterCaller(new("task-caller", hoot ? "own-chat" : null, null, true, AiPermissionMode.Ask,
      ["tasks.comment"], [McpTier.Act], ["tasks:*", "projects:sample", "folders:C:/Work/Sample", "agents:reviewer", .. sessions.Select(s => "sessions:" + s)],
      (clock?.Now ?? DateTimeOffset.UtcNow).AddMinutes(1), SeatId: hoot ? HootDesk.Seat : null),
      (_, _, _, _, _) => ValueTask.FromResult(current?.Invoke() ?? true));
    return (door, caller);
  }
  private static ValueTask<System.Text.Json.JsonElement> Post(McpDoor door, McpRegistration caller, string task, string body = "@reviewer please read") =>
    door.CallAsync(caller.Id, "tasks.comment", TasksMcp.Value(new { task, kind = "question", body }));

  [Fact] public async Task OfflineMentionNeverAcquiresAnUngrantableFutureSession()
  {
    var f = new TaskFixture(); var task = f.Create(); f.People["reviewer"] = f.People["reviewer"] with { SessionId = null };
    var (door, caller) = Door(f, []); await Post(door, caller, task.Id);
    f.People["reviewer"] = f.People["reviewer"] with { SessionId = "new-ungranted-chat" };
    await f.Tasks.DeliverMentionsAsync(task.Id);
    var note = Assert.Single(f.Tasks.Mentions()); Assert.False(note.Delivered); Assert.Null(note.SessionId);
    Assert.Contains("permission expired or changed", note.Problem); Assert.Empty(f.Runner.Notifications);
    Assert.Equal("task-caller", note.Authority!.CallerId); Assert.Equal("sample", note.Authority.ProjectId);
    Assert.Equal("C:/Work/Sample", note.Authority.Folder);
  }

  [Theory]
  [InlineData("expire")]
  [InlineData("revoke")]
  [InlineData("invalidate")]
  [InlineData("update")]
  public async Task QueuedMentionRechecksTheOriginalLiveAuthorityOnEveryRetry(string change)
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true; var clock = new Clock(); var valid = true;
    var (door, caller) = Door(f, ["existing-session"], clock, () => valid);
    await Post(door, caller, task.Id);
    var originalId = Assert.Single(f.Tasks.Mentions()).Id;
    if (change == "expire") clock.Now += TimeSpan.FromMinutes(2);
    else if (change == "revoke") door.Revoke(caller.Id);
    else if (change == "invalidate") valid = false;
    else door.UpdateCaller(caller.Id, new("task-caller", null, null, true, AiPermissionMode.Ask, ["tasks.comment"], [McpTier.Act],
      ["tasks:*", "projects:sample", "folders:C:/Work/Sample", "agents:reviewer"], clock.Now.AddMinutes(1)));
    f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id);
    var pending = Assert.Single(f.Tasks.Mentions()); Assert.Equal(originalId, pending.Id); Assert.False(pending.Delivered);
    Assert.Contains("permission expired or changed", pending.Problem); Assert.Empty(f.Runner.Notifications);
  }

  [Fact] public async Task AuthorityIsRecheckedAfterPreparingALongNotification()
  {
    var f = new TaskFixture(); var task = f.Create(); var clock = new Clock();
    var (door, caller) = Door(f, ["existing-session"], clock);
    f.Files.BeforeSave = () => clock.Now += TimeSpan.FromMinutes(2);
    // The outer call also refuses its result after expiry; its durable comment
    // must still be pending, with no notification submitted in the meantime.
    await Assert.ThrowsAsync<McpRefusal>(async () => await Post(door, caller, task.Id, "@reviewer " + new string('x', 1000)));
    Assert.False(Assert.Single(f.Tasks.Mentions()).Delivered);
    Assert.Contains("permission expired or changed", f.Tasks.Mentions()[0].Problem); Assert.Empty(f.Runner.Notifications);
  }

  [Fact] public async Task ReopenedOutboxNeedsFreshAuthorityAndRepostingProvidesAnExplicitPath()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true;
    var (door, caller) = Door(f, ["existing-session"]); await Post(door, caller, task.Id);
    f.Tasks = f.Open(); f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.Contains("Post the mention again", Assert.Single(f.Tasks.Mentions()).Problem); Assert.Empty(f.Runner.Notifications);
    var (freshDoor, freshCaller) = Door(f, ["existing-session"]); await Post(freshDoor, freshCaller, task.Id);
    Assert.Single(f.Runner.Notifications); Assert.Single(f.Tasks.Mentions(), m => m.Delivered);
    Assert.Single(f.Tasks.Mentions(), m => !m.Delivered);
  }

  [Fact] public async Task QueuedMentionPinsTheApprovedSessionAndDoesNotFollowAgentOrLeadChanges()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true;
    var (door, caller) = Door(f, ["existing-session", "different-session"]); await Post(door, caller, task.Id);
    f.People["reviewer"] = f.People["reviewer"] with { SessionId = "different-session" };
    f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.Equal("existing-session", Assert.Single(f.Tasks.Mentions()).SessionId);
    Assert.Contains("destination changed", Assert.Single(f.Tasks.Mentions()).Problem); Assert.Empty(f.Runner.Notifications);
    f.People["reviewer"] = f.People["reviewer"] with { SessionId = "existing-session", Identity = "different-agent" };
    await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.Contains("destination changed", Assert.Single(f.Tasks.Mentions()).Problem); Assert.Empty(f.Runner.Notifications);
  }

  [Fact] public async Task MovedTaskCannotReuseOldMentionAuthority()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true;
    var (door, caller) = Door(f, ["existing-session"]); await Post(door, caller, task.Id);
    f.Tasks.Update(task.Id, TaskService.Draft(f.Tasks.Get(task.Id)) with { ProjectId = "other", Folder = "C:/Work/Other" }, TaskActor.Owner);
    f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.Contains("approved project or folder", Assert.Single(f.Tasks.Mentions()).Problem); Assert.Empty(f.Runner.Notifications);
  }

  [Fact] public async Task CurrentAuthorityCanRetryAndKeepsItsStableReceiptIdentity()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true;
    var (door, caller) = Door(f, ["existing-session"]); await Post(door, caller, task.Id);
    var id = Assert.Single(f.Tasks.Mentions()).Id;
    f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id); await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.True(Assert.Single(f.Tasks.Mentions()).Delivered); Assert.Equal(id, f.Tasks.Mentions()[0].Id); Assert.Single(f.Runner.Notifications);
  }

  [Theory]
  [InlineData("session:own-chat", "own-chat", "hoot")]
  [InlineData("lead:sample", "own-chat", "hoot")]
  [InlineData("session:own-chat", "own-chat", "session:own-chat")]
  public async Task HootTaskCommentRefusesItsOwnResolvedSessionAliases(string alias, string session, string identity)
  {
    var f = new TaskFixture(); var task = f.Create(); f.People[alias] = new(alias, "Hoot alias", "agent", session, identity);
    var (door, caller) = Door(f, ["own-chat"], hoot: true);
    // A lead grant is deliberately present: refusal comes from identity, not a missing grant.
    door.UpdateCaller(caller.Id, new("task-caller", "own-chat", null, true, AiPermissionMode.Ask, ["tasks.comment"], [McpTier.Act],
      ["tasks:*", "projects:sample", "folders:C:/Work/Sample", "agents:lead:sample", "sessions:own-chat"], DateTimeOffset.UtcNow.AddHours(1), SeatId: HootDesk.Seat));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await Post(door, caller, task.Id, "@[" + alias + "] do another turn"));
    Assert.Empty(f.Tasks.Get(task.Id).Comments); Assert.Empty(f.Tasks.Mentions()); Assert.Empty(f.Runner.Notifications);
  }

  [Fact] public async Task DeferredHootAliasFenceRunsAgainBeforeSending()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true;
    await f.Tasks.CommentAsync(task.Id, "@reviewer check this", TaskActor.Owner);
    var saved = f.Persistence.State!; var row = Assert.Single(saved.Tasks); var comment = Assert.Single(row.Comments);
    var note = Assert.Single(saved.Mentions);
    var hoot = new TaskActor("hoot", "Hoot", "hoot");
    f.Persistence.State = saved with
    {
      Tasks = [row with { Comments = [comment with { Author = hoot }] }],
      Mentions = [note with { TargetIdentity = "hoot", Authority = note.Authority! with { Owner = false, CallerId = "hoot-caller", SeatId = HootDesk.Seat } }]
    };
    f.People["reviewer"] = f.People["reviewer"] with { Identity = "hoot" };
    f.Tasks = f.Open(); f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.Contains("cannot send a task mention to itself", Assert.Single(f.Tasks.Mentions()).Problem); Assert.Empty(f.Runner.Notifications);
  }

  [Fact] public async Task NotificationSinkRefusesMultilineShellTextBeforeTheDummyAdapterReceivesInput()
  {
    var writes = 0;
    ValueTask DummyShellAdapter(string id, string text, CancellationToken ct) { writes++; return ValueTask.CompletedTask; }
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await TaskNotificationSink.SendAsync("powershell", "Get-Location\nWrite-Output unsafe\n",
      _ => false, DummyShellAdapter));
    Assert.Equal(0, writes);
    await TaskNotificationSink.SendAsync("agent-chat", "A normal comment\nSecond line", _ => true, DummyShellAdapter);
    Assert.Equal(1, writes);
  }

  [Theory]
  [InlineData("shell", "terminal")]
  [InlineData("shell", "chat")]
  [InlineData("codex", "terminal")]
  public void MentionResolverRefusesTerminalDestinations(string provider, string mode)
  {
    var session = new ProjectSession("shell-id", "Dummy shell", provider, "C:/Work/Sample", "running", Mode: mode);
    Assert.False(TaskRecipients.IsNotificationChat(session));
    // The session branch must refuse before consulting agent state.
    Assert.Null(TaskRecipients.Resolve("session:shell-id", null!, new TaskFixture().Projects, () => [session]));
  }

  [Theory]
  [InlineData("ended", TaskRunState.Ended)]
  [InlineData("needs-you", TaskRunState.NeedsYou)]
  [InlineData("yielded", TaskRunState.Yielded)]
  public async Task FastLifecycleEventSurvivesTheRunnerReturning(string signal, TaskRunState expected)
  {
    var f = new TaskFixture(); var task = f.Create();
    f.Runner.AfterPrepared = session =>
    {
      if (signal == "yielded") f.Tasks.YieldSession(session, "The agent yielded quickly.");
      else f.Tasks.ObserveSession(session, signal == "ended", signal == "needs-you");
    };
    await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner);
    Assert.Equal(expected, Assert.Single(f.Tasks.Runs()).State); Assert.True(f.Tasks.Get(task.Id).NeedsYou);
    Assert.Equal("Stuck", f.Tasks.Get(task.Id).Status);
  }

  [Fact] public async Task HootBriefNamesTheRealAssigningActorAndDoesNotCreateOwnerPermission()
  {
    var f = new TaskFixture(); var task = f.Create(); var actor = new TaskActor("reviewer", "Reviewer", "agent");
    await f.Tasks.AssignAsync(task.Id, "reviewer", actor);
    Assert.Equal(actor, f.Runner.Launch!.AssignedBy);
    var context = HootTaskTurns.Context("The supplied task text.", f.Runner.Launch.AssignedBy);
    Assert.Contains("assigned by Reviewer (agent)", context); Assert.Contains("grants no fresh owner permission", context);
    Assert.DoesNotContain("assigned by the person", context);
    Assert.Contains("unknown actor", HootTaskTurns.Context("Legacy task", null));
  }
}
