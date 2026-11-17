using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.NewSession;

public sealed class NewSessionPermissionTests
{
  private static NewSessionStart Start(string provider = "claude") => new(ProjectIdentity.IndependentId, null, provider, "account", null, null, "chat");
  private static NewSessionWorld World() => new([], [new("agent", "Agent", ProjectIdentity.IndependentId, "claude")],
    ["claude", "codex", "gemini", "shell"], _ => ["account", "other"], _ => "account", "claude");

  [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task A_chosen_mode_reaches_the_single_start_and_survives_local_memory_serialization(string provider)
  {
    foreach (var mode in ChatPermissionModes.Supported(provider))
    {
      var selected = NewSessionPresets.WithPermission(Start(provider), mode);
      var restored = JsonSerializer.Deserialize<NewSessionStart>(JsonSerializer.Serialize(selected))!;
      Assert.Equal(mode, restored.Permission);
      Assert.Equal(mode, NewSessionPresets.Resolve(restored, World()).Permission);
      NewSessionStart? received = null;
      var flow = new NewSessionFlow((start, _, _) => { received = start; return Task.FromResult("one"); });
      var result = await flow.SendAsync("hello", 0, restored, Task.CompletedTask, TimeSpan.FromSeconds(1));
      Assert.Equal(NewSessionOutcome.Started, result.Outcome);
      Assert.Equal(mode, received?.Permission);
    }
  }

  [Fact]
  public void Changing_account_or_presentation_keeps_the_pick_and_changing_AI_resets_it()
  {
    var selected = NewSessionPresets.WithPermission(Start(), AiPermissionMode.Plan);
    var account = NewSessionPresets.WithProvider(selected, "claude", World(), "other");
    Assert.Equal(AiPermissionMode.Plan, account.Permission);
    Assert.Equal(AiPermissionMode.Plan, NewSessionPresets.WithMode(account, "terminal").Permission);
    Assert.Null(NewSessionPresets.WithProvider(account, "codex", World()).Permission);
    Assert.Null(NewSessionPresets.WithProvider(account, "shell", World()).Permission);
    Assert.Null(NewSessionPresets.WithAgent(account, "agent", World()).Permission);
  }

  [Fact]
  public void Unsupported_modes_are_refused_and_stale_picks_are_not_restored_as_active()
  {
    Assert.Throws<ArgumentException>(() => NewSessionPresets.WithPermission(Start("codex"), AiPermissionMode.Auto));
    Assert.Throws<ArgumentException>(() => NewSessionPresets.WithPermission(Start("shell"), AiPermissionMode.Bypass));
    Assert.Null(NewSessionPresets.Resolve(Start("gemini") with { Permission = AiPermissionMode.Auto }, World()).Permission);
    var oldSavedStart = JsonSerializer.Deserialize<NewSessionStart>("""{"ProjectId":"independent","AgentId":null,"Provider":"claude","AccountId":"account","Model":null,"Effort":null,"Mode":"chat"}""")!;
    Assert.Null(oldSavedStart.Permission);
  }
}
