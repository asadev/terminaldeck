using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Chats;

// Only offer modes with a real provider mapping. A missing mapping is a refusal,
// never an instruction in the prompt or a silent fallback to broader access.
public static class ChatPermissionModes
{
  public static IReadOnlyList<AiPermissionMode> Supported(string provider) => provider switch
  {
    "claude" => [AiPermissionMode.Ask, AiPermissionMode.Plan, AiPermissionMode.Auto, AiPermissionMode.AcceptEdits, AiPermissionMode.Bypass],
    "codex" => [AiPermissionMode.Ask, AiPermissionMode.Plan, AiPermissionMode.AcceptEdits, AiPermissionMode.Bypass],
    "gemini" => [AiPermissionMode.Ask, AiPermissionMode.Plan, AiPermissionMode.AcceptEdits, AiPermissionMode.Bypass],
    _ => []
  };
  public static void Validate(string provider, AiPermissionMode mode)
  { if (!Supported(provider).Contains(mode)) throw new ArgumentException("Choose a permission mode supported by this coding AI."); }
  public static string Claude(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask => "default", AiPermissionMode.Plan => "plan", AiPermissionMode.Auto => "auto",
    AiPermissionMode.AcceptEdits => "acceptEdits", AiPermissionMode.Bypass => "bypassPermissions",
    _ => throw new ArgumentException("Choose a supported Claude permission mode.")
  };
  public static string Gemini(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask => "default", AiPermissionMode.Plan => "plan", AiPermissionMode.AcceptEdits => "auto_edit",
    AiPermissionMode.Bypass => "yolo", _ => throw new ArgumentException("Choose a supported Gemini permission mode.")
  };
  public static string CodexApproval(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask => "on-request", AiPermissionMode.Plan or AiPermissionMode.AcceptEdits or AiPermissionMode.Bypass => "never",
    _ => throw new ArgumentException("Choose a supported Codex permission mode.")
  };
  public static string CodexSandbox(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask or AiPermissionMode.AcceptEdits => "workspace-write", AiPermissionMode.Plan => "read-only", AiPermissionMode.Bypass => "danger-full-access",
    _ => throw new ArgumentException("Choose a supported Codex permission mode.")
  };
  public static string Label(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask => "Asks before changes", AiPermissionMode.Plan => "Plans only", AiPermissionMode.Auto => "Automatic permissions",
    AiPermissionMode.AcceptEdits => "Changes without asking", AiPermissionMode.Bypass => "Bypass permissions", _ => "Unknown"
  };
  public static string Explain(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask => "asks before it changes anything", AiPermissionMode.Plan => "reads and plans, changes nothing",
    AiPermissionMode.Auto => "decides for itself which actions are safe", AiPermissionMode.AcceptEdits => "edits files without asking, asks for the rest",
    AiPermissionMode.Bypass => "does everything without asking", _ => ""
  };
  // Out of the box a new chat starts in Bypass, or Auto where the AI has it (Claude),
  // like the Mac. The person's own default in Settings wins when this AI supports it.
  public static AiPermissionMode DefaultFor(string provider, AiPermissionMode? chosen = null)
  {
    var supported = Supported(provider);
    if (chosen is { } c && supported.Contains(c)) return c;
    return supported.Contains(AiPermissionMode.Auto) ? AiPermissionMode.Auto : supported.Contains(AiPermissionMode.Bypass) ? AiPermissionMode.Bypass : AiPermissionMode.Ask;
  }
}
