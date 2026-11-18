using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskEfficiencyTests
{
  private const string Account = "11111111111111111111111111111111";
  private sealed class Runner(string completion, bool reuse = true) : ITaskRunner
  {
    public string Session = Guid.NewGuid().ToString();
    public bool CanStart(string mode) => true;
    public async ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken ct)
    {
      await prepared(new(Session, launch.Task.ProjectId, launch.Task.Folder, Account, "reviewer", new(ReuseContext: reuse, Completion: completion), "scope"), ct); return Session;
    }
    public ValueTask NotifyAsync(string id, string text, CancellationToken ct) => ValueTask.CompletedTask;
  }
  private static (TaskFixture Fixture, TaskService Tasks, Runner Runner, string Id) Make(string completion = "park")
  {
    var fixture = new TaskFixture(); var runner = new Runner(completion);
    var tasks = new TaskService(new TaskStore(fixture.Persistence), fixture.Projects, id => fixture.People.GetValueOrDefault(id), runner, fixture.Files);
    var task = tasks.Create(new("Do the review", ProjectId: "sample"), TaskActor.Owner);
    return (fixture, tasks, runner, task.Id);
  }

  [Theory] [InlineData("park", true)] [InlineData("stop", false)]
  public async Task Mark_done_waits_for_the_reply_and_a_confirmed_process_close(string completion, bool parked)
  {
    var f = Make(completion); await f.Tasks.AssignAsync(f.Id, "reviewer", TaskActor.Owner);
    var pending = f.Tasks.Status(f.Id, "Done", TaskActor.Owner);
    Assert.NotEqual("Done", pending.Status); Assert.True(TaskExtras.Of(pending).CompletionRequested);
    var closes = 0; var canClose = false; var conversation = Guid.NewGuid().ToString();
    var owner = new TaskCompletion(f.Tasks, (_, _) => { closes++; return ValueTask.FromResult(new TaskFinishReceipt(canClose, conversation)); });
    await owner.ObserveAsync(f.Runner.Session, TaskSessionSignal.Working, default); Assert.Equal(0, closes);
    await owner.ObserveAsync(f.Runner.Session, TaskSessionSignal.Idle, default); Assert.NotEqual("Done", f.Tasks.Get(f.Id).Status);
    canClose = true; await owner.ObserveAsync(f.Runner.Session, TaskSessionSignal.Idle, default);
    Assert.Equal("Done", f.Tasks.Get(f.Id).Status);
    var run = Assert.Single(f.Tasks.Runs()); Assert.Equal(TaskRunState.Ended, run.State); Assert.Equal(parked, run.Parked);
    Assert.Equal(parked ? conversation : null, run.ConversationId);
  }

  [Fact]
  public async Task A_cancelled_completion_does_not_close_the_owned_session()
  {
    var f = Make(); await f.Tasks.AssignAsync(f.Id, "reviewer", TaskActor.Owner);
    f.Tasks.Status(f.Id, "Done", TaskActor.Owner); f.Tasks.Status(f.Id, "Stuck", TaskActor.Owner);
    var calls = 0;
    var owner = new TaskCompletion(f.Tasks, (_, _) => { calls++; return ValueTask.FromResult(new TaskFinishReceipt(true)); });
    await owner.ObserveAsync(f.Runner.Session, TaskSessionSignal.Idle, default);
    Assert.Equal(0, calls); Assert.Equal("Stuck", f.Tasks.Get(f.Id).Status);
  }

  [Fact]
  public async Task Reuse_requires_exact_account_settings_project_and_a_parked_ended_conversation()
  {
    var f = Make(); await f.Tasks.AssignAsync(f.Id, "reviewer", TaskActor.Owner, "chat");
    f.Tasks.Status(f.Id, "Done", TaskActor.Owner);
    var conversation = Guid.NewGuid().ToString();
    f.Tasks.FinishRequested(Assert.Single(f.Tasks.Runs()).Id, new(true, conversation));
    var run = Assert.Single(f.Tasks.Runs());
    var plan = new AgentLaunchPlan(Guid.NewGuid().ToString(), "reviewer", "seat", "sample", run.Folder, "claude", Account, Account, "model", "auto", "instructions", null, "Next task", "job", "chat", Efficiency: new(ReuseContext: true), ContextSignature: "scope");
    var source = new ChatRecord(1, new(f.Runner.Session, "claude", run.Folder, "Old task", Account, Account, new()), "worker", [], [], ConversationId: conversation, Ended: true);
    var state = f.Fixture.Persistence.State!;
    Assert.Equal(conversation, AgentContextPolicy.Parked(plan, state, [], [source]));
    Assert.Null(AgentContextPolicy.Parked(plan with { AccountId = Guid.NewGuid().ToString("N") }, state, [], [source]));
    Assert.Null(AgentContextPolicy.Parked(plan with { ContextSignature = "changed-security" }, state, [], [source]));
    Assert.Null(AgentContextPolicy.Parked(plan, state, [], [source with { Ended = false, Busy = true }]));
    Assert.Null(AgentContextPolicy.Parked(plan with { ProjectId = "other" }, state, [], [source]));
  }

  [Fact]
  public void New_task_policy_does_not_add_instructions_when_unset_and_names_real_work_tools_when_enabled()
  {
    Assert.Equal("", AgentBudgetPolicy.Brief(null));
    var text = AgentBudgetPolicy.Brief(new(SerializeHeavyJobs: true, Completion: "park"));
    Assert.Contains("agents_work", text); Assert.Contains("action wait", text); Assert.DoesNotContain("agents_work_wait", text);
    Assert.Contains("keeps this conversation", text);
  }
  [Fact]
  public void The_terminal_owner_receives_exact_reuse_and_addon_flags_without_changing_unset_launches()
  {
    var id = Guid.NewGuid().ToString();
    var plan = new AgentLaunchPlan(id, "reviewer", "seat", "sample", "C:/Work/Sample", "claude", Account, Account, "", "auto", "instructions", null, "Task", "new job", "terminal");
    var ordinary = KeeperAgentSessionGateway.Definition(plan);
    Assert.False(ordinary.AddonsOff); Assert.False(ordinary.RequiresDeckTools); Assert.False(ordinary.ResumeWithPrompt); Assert.Null(ordinary.ConversationId);
    var conversation = Guid.NewGuid().ToString();
    var applied = KeeperAgentSessionGateway.Definition(plan with { ConversationId = conversation, Efficiency = new(AddonsOff: true) });
    Assert.True(applied.AddonsOff); Assert.True(applied.RequiresDeckTools); Assert.True(applied.ResumeWithPrompt); Assert.Equal(conversation, applied.ConversationId);
    Assert.Contains("new job", applied.InitialPrompt);
  }

  [Fact]
  public async Task A_yielded_but_owned_idle_session_can_still_be_parked_when_its_task_finishes()
  {
    var f = Make(); await f.Tasks.AssignAsync(f.Id, "reviewer", TaskActor.Owner);
    f.Tasks.YieldSession(f.Runner.Session, "Idle");
    f.Tasks.Status(f.Id, "Done", TaskActor.Owner);
    Assert.True(TaskExtras.Of(f.Tasks.Get(f.Id)).CompletionRequested);
    var completion = new TaskCompletion(f.Tasks, (_, _) => ValueTask.FromResult(new TaskFinishReceipt(true, Guid.NewGuid().ToString())));
    await completion.ObserveAsync(f.Runner.Session, TaskSessionSignal.Idle, default);
    Assert.Equal("Done", f.Tasks.Get(f.Id).Status); Assert.True(Assert.Single(f.Tasks.Runs()).Parked);
  }

}
