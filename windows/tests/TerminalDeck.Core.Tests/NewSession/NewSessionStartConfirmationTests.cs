using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.NewSession;

public sealed class NewSessionStartConfirmationTests
{
  private static AgentLaunchPlan Plan(string provider = "claude") => new(Guid.NewGuid().ToString(), null, null, "independent",
    Path.GetTempPath(), provider, "account", "home", "opus", "high", "", null, "New terminal", "Short first prompt", "terminal", AiPermissionMode.Ask);

  [Fact]
  public async Task Real_keeper_declared_Claude_conversation_confirms_the_already_started_terminal()
  {
    var processes = new FakeProcessKeeper();
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes);
    var gateway = KeeperAgentSessionGateway.FromKeeper(keeper);
    var plan = Plan();
    var started = await gateway.StartAsync(plan, default);
    var saved = keeper.Get(plan.SessionId);
    Assert.Equal(new AgentSessionStarted(plan.SessionId, "terminal"), started);
    Assert.True(saved.DeclaredConversation);
    Assert.True(Guid.TryParseExact(saved.Definition.ConversationId, "D", out _));
    Assert.Equal(KeeperAgentSessionGateway.Definition(plan), saved.Definition with { ConversationId = null });
    Assert.Single(processes.Leases);
  }

  [Theory]
  [InlineData("id")]
  [InlineData("provider")]
  [InlineData("folder")]
  [InlineData("title")]
  [InlineData("account")]
  [InlineData("home")]
  [InlineData("model")]
  [InlineData("effort")]
  [InlineData("permission")]
  [InlineData("prompt")]
  public async Task Declared_conversation_never_hides_another_changed_launch_field(string field)
  {
    var gateway = new KeeperAgentSessionGateway((definition, _) =>
    {
      var declared = definition with { ConversationId = Guid.NewGuid().ToString() };
      var changed = field switch
      {
        "id" => declared with { Id = Guid.NewGuid().ToString() },
        "provider" => declared with { Provider = "codex" },
        "folder" => declared with { Cwd = Path.Combine(Path.GetTempPath(), "other") },
        "title" => declared with { Title = "Other title" },
        "account" => declared with { AccountId = "other" },
        "home" => declared with { AccountHome = "other" },
        "model" => declared with { Model = "other" },
        "effort" => declared with { Effort = "low" },
        "permission" => declared with { Permission = "bypass" },
        "prompt" => declared with { InitialPrompt = "Other first prompt" },
        _ => throw new ArgumentException("Unknown test field")
      };
      return ValueTask.FromResult(new SessionRecord(changed, "creation", SessionState.Running, DeclaredConversation: true));
    });
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await gateway.StartAsync(Plan(), default));
  }

  [Theory]
  [InlineData("claude", false, "8f0e10d6-b9a1-4be5-b752-ac416ae440ed")]
  [InlineData("codex", true, "8f0e10d6-b9a1-4be5-b752-ac416ae440ed")]
  [InlineData("claude", true, "invalid-conversation")]
  public async Task Unexpected_or_invalid_conversation_changes_still_refuse_confirmation(string provider, bool declared, string conversation)
  {
    var gateway = new KeeperAgentSessionGateway((definition, _) => ValueTask.FromResult(new SessionRecord(
      definition with { ConversationId = conversation }, "creation", SessionState.Running, DeclaredConversation: declared)));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await gateway.StartAsync(Plan(provider), default));
  }
}
