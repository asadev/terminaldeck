using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class AgentIdleCompletionTests
{
  private sealed class Processes : ISessionProcessKeeper
  {
    public ProcessPresence Presence = ProcessPresence.Live;
    public bool Busy;
    public bool ConfirmsQuit = true;
    public int Quits;
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Live, "owned-lease"));
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(Presence, "owned-lease", ForegroundBusy: Busy));
    public ValueTask QuitAsync(string lease, CancellationToken ct) { Assert.Equal("owned-lease", lease); Quits++; if (ConfirmsQuit) Presence = ProcessPresence.Dead; return ValueTask.CompletedTask; }
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
  }

  [Fact]
  public async Task Completion_rechecks_exact_identity_idle_and_confirmed_death_before_receipting()
  {
    var processes = new Processes(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes);
    var row = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "codex", "C:/Work", "Task", ConversationId: Guid.NewGuid().ToString()));
    Assert.False(await keeper.TryStopIdleAsync(row with { CreationKey = "stale-worker" })); Assert.Equal(0, processes.Quits);
    processes.Busy = true; Assert.False(await keeper.TryStopIdleAsync(row)); Assert.Equal(0, processes.Quits);
    processes.Busy = false; processes.Presence = ProcessPresence.Unknown;
    Assert.False(await keeper.TryStopIdleAsync(row)); Assert.Equal(0, processes.Quits);
    processes.Presence = ProcessPresence.Live; processes.ConfirmsQuit = false;
    Assert.False(await keeper.TryStopIdleAsync(row)); Assert.NotEqual(SessionState.Exited, keeper.Get(row.Definition.Id).State);
    processes.ConfirmsQuit = true; Assert.True(await keeper.TryStopIdleAsync(row));
    Assert.Equal(SessionState.Exited, keeper.Get(row.Definition.Id).State);
  }

  [Fact]
  public async Task The_new_resume_prompt_is_marked_delivered_only_after_a_live_process_receipt()
  {
    var processes = new Processes(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes);
    var row = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "codex", "C:/Work", "Task", ConversationId: Guid.NewGuid().ToString(), InitialPrompt: "New task") { ResumeWithPrompt = true });
    Assert.True(row.ResumePromptDelivered); Assert.True(row.Resume);
    var ordinary = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "codex", "C:/Work", "Plain session"));
    Assert.False(ordinary.ResumePromptDelivered);
  }
}
