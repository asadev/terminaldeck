using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class UmerPermissionAndEnterTests
{
  [Theory]
  [InlineData("claude", AiPermissionMode.Auto)]
  [InlineData("codex", AiPermissionMode.Bypass)]
  [InlineData("gemini", AiPermissionMode.Bypass)]
  public void OutOfTheBoxDefaultIsBypassOrAutoNeverAsk(string provider, AiPermissionMode expected) =>
    Assert.Equal(expected, ChatPermissionModes.DefaultFor(provider));
  [Fact] public void ChosenDefaultWinsOnlyWhereTheAiSupportsIt()
  {
    Assert.Equal(AiPermissionMode.Plan, ChatPermissionModes.DefaultFor("codex", AiPermissionMode.Plan));
    Assert.Equal(AiPermissionMode.Bypass, ChatPermissionModes.DefaultFor("codex", AiPermissionMode.Auto));
  }
  [Fact] public void SettingsDefaultRoundTripsAndFeedsNewChats()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "umer-perm-" + Guid.NewGuid()));
    try
    {
      Assert.Equal(AiPermissionMode.Auto, GeneralSettings.NewChatPermission(root, "claude"));
      var settings = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
      settings.Patch(JsonSerializer.SerializeToElement(new { defaultPermission = "Plan" }));
      Assert.Equal(AiPermissionMode.Plan, GeneralSettings.NewChatPermission(root, "gemini"));
      Assert.Throws<ArgumentException>(() => settings.Patch(JsonSerializer.SerializeToElement(new { defaultPermission = "nope" })));
    }
    finally { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public void EveryModeHasAOneLineExplanation()
  {
    foreach (var provider in new[] { "claude", "codex", "gemini" })
      foreach (var mode in ChatPermissionModes.Supported(provider)) Assert.NotEmpty(ChatPermissionModes.Explain(mode));
  }
  [Fact] public void EnterSendsShiftEnterIsNewLineAndEmptyEnterAddsNothing()
  {
    var enter = new ComposerEnter(() => 10_000);
    Assert.Equal(ComposerEnterAction.Send, enter.Decide(true, false, true));
    Assert.Equal(ComposerEnterAction.PassThrough, enter.Decide(true, true, true));
    Assert.Equal(ComposerEnterAction.Swallow, enter.Decide(true, false, false));
    Assert.Equal(ComposerEnterAction.PassThrough, enter.Decide(false, false, true));
  }
  [Fact] public void EnterInsideAnInputMethodNeverSends()
  {
    long t = 10_000; var enter = new ComposerEnter(() => t);
    enter.CompositionStarted();
    Assert.Equal(ComposerEnterAction.PassThrough, enter.Decide(true, false, true));
    enter.CompositionEnded(); t += 50;
    Assert.Equal(ComposerEnterAction.PassThrough, enter.Decide(true, false, true));
    t += 500;
    Assert.Equal(ComposerEnterAction.Send, enter.Decide(true, false, true));
  }
}
