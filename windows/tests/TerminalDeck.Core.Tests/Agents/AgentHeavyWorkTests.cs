using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Agents;

public sealed class AgentHeavyWorkTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-agent-work-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
  private AgentHeavyWork Work(Func<string, bool?>? alive = null) => new(new JsonStateStore<AgentWorkState>(AppDataRoot.Explicit(folder), "work"), alive ?? (_ => true));

  [Fact]
  public async Task Two_agents_wait_for_one_real_owner_and_the_wait_is_event_driven()
  {
    var work = Work();
    var first = await work.AcquireAsync("one", "Build", default);
    var second = await work.AcquireAsync("two", "Tests", default);
    Assert.True(first.Granted); Assert.False(second.Granted);
    var waiting = work.WaitAsync("two", second.Ticket, default);
    Assert.False(waiting.IsCompleted);
    await work.ReleaseAsync("one", first.Ticket, false, default);
    Assert.True((await waiting.WaitAsync(TimeSpan.FromSeconds(2))).Granted);
    Assert.Single(await work.ListAsync(default));
  }

  [Fact]
  public async Task Restart_keeps_a_live_ticket_and_an_unknown_session_is_not_pruned()
  {
    var first = await Work().AcquireAsync("one", "Build", default);
    var restored = Work(_ => null);
    await restored.ReconcileAsync();
    Assert.Equal(first.Ticket, Assert.Single(await restored.ListAsync(default)).Ticket);
    Assert.False((await restored.AcquireAsync("two", "Tests", default)).Granted);
    await Assert.ThrowsAsync<McpRefusal>(() => restored.ReleaseAsync("two", first.Ticket, false, default));
  }

  [Fact]
  public async Task A_positively_ended_owner_promotes_the_next_agent()
  {
    var alive = true;
    var work = Work(id => id == "one" ? alive : true);
    await work.AcquireAsync("one", "Build", default);
    var next = await work.AcquireAsync("two", "Tests", default);
    var waiting = work.WaitAsync("two", next.Ticket, default);
    alive = false; await work.ReconcileAsync();
    Assert.True((await waiting.WaitAsync(TimeSpan.FromSeconds(2))).Granted);
  }
}
