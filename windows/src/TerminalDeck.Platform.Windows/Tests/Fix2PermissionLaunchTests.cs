using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class Fix2PermissionLaunchTests
{
  [Theory]
  [InlineData("claude", AiPermissionMode.Ask, "--permission-mode", "default")]
  [InlineData("claude", AiPermissionMode.Plan, "--permission-mode", "plan")]
  [InlineData("claude", AiPermissionMode.Auto, "--permission-mode", "auto")]
  [InlineData("claude", AiPermissionMode.AcceptEdits, "--permission-mode", "acceptEdits")]
  [InlineData("claude", AiPermissionMode.Bypass, "--permission-mode", "bypassPermissions")]
  [InlineData("gemini", AiPermissionMode.Ask, "--approval-mode", "default")]
  [InlineData("gemini", AiPermissionMode.Plan, "--approval-mode", "plan")]
  [InlineData("gemini", AiPermissionMode.AcceptEdits, "--approval-mode", "auto_edit")]
  [InlineData("gemini", AiPermissionMode.Bypass, "--approval-mode", "yolo")]
  public void NativeProviderLaunchCarriesTheSavedOwnerMode(string provider, AiPermissionMode mode, string flag, string value)
  {
    var path = Path.Combine(Path.GetTempPath(), "td-fix2-mode-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path);
    try
    {
      var account = Guid.NewGuid().ToString("N"); var root = AppDataRoot.Explicit(path);
      var chat = new ChatRecord(1, new(Guid.NewGuid().ToString(), provider, path, "Mode proof", account, account, new(), PermissionMode: mode), Guid.NewGuid().ToString("N"), [], []);
      var launch = new WindowsChatLaunchPlanner(root, @"C:\TD\tools\ai").Plan(chat);
      var arguments = launch.Arguments.ToList(); var at = arguments.IndexOf(flag);
      Assert.True(at >= 0); Assert.Equal(value, arguments[at + 1]);
      Assert.Equal(path, launch.WorkingDirectory);
      Assert.DoesNotContain("ANTHROPIC_API_KEY", launch.Environment.Keys); Assert.DoesNotContain("OPENAI_API_KEY", launch.Environment.Keys);
    }
    finally { Directory.Delete(path, true); }
  }

  [Fact]
  public void CompatibilityExecCannotSilentlyDropBypassAndUnsupportedCodexModesRefuse()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-fix2-exec-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path);
    try
    {
      var account = Guid.NewGuid().ToString("N"); var root = AppDataRoot.Explicit(path);
      var chat = new ChatRecord(1, new(Guid.NewGuid().ToString(), "codex", path, "Mode proof", account, account, new(), PermissionMode: AiPermissionMode.Bypass), Guid.NewGuid().ToString("N"), [], []);
      Assert.Throws<InvalidOperationException>(() => new WindowsChatLaunchPlanner(root, @"C:\TD\tools\ai", false).Plan(chat));
      Assert.Throws<ArgumentException>(() => (chat.Definition with { PermissionMode = AiPermissionMode.AcceptEdits }).Validate());
    }
    finally { Directory.Delete(path, true); }
  }
}
