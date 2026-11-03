using TerminalDeck.Core.Sessions;
namespace TerminalDeck.Core.Hooks;

public static class ProviderHookProjection
{
  public static string? Desktop(SessionRecord session, ProviderHookEvent? observation)
  {
    if (observation is null || session.Definition.Purpose is not null || session.State != SessionState.Running || observation.Provider != session.Definition.Provider ||
      observation.At.ToUnixTimeMilliseconds() < session.CreatedAt) return null;
    return observation.Event switch
    {
      "SessionStart" => "ready",
      "UserPromptSubmit" or "BeforeAgent" or "PreToolUse" or "PostToolUse" or "PostToolUseFailure" or "BeforeTool" or "AfterTool" => "working",
      "PermissionRequest" or "Notification" => "needs-input",
      "StopFailure" => "failed",
      "Stop" or "AfterAgent" or "SessionEnd" => "completed",
      _ => null
    };
  }
  public static string? Phone(SessionRecord session, ProviderHookEvent? observation) => Desktop(session, observation) switch
  { "working" => "working", "needs-input" or "failed" => "waiting", "ready" or "completed" => "idle", _ => null };
}
