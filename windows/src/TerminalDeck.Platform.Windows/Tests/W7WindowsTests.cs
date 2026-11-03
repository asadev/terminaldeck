using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Windows.Tests;

public sealed class W7WindowsTests
{
  [Fact] public void DefaultCodexLaunchIsPersistentAndPinsItsIsolatedCredentialFile()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-w7-planner-" + Guid.NewGuid().ToString("N"));
    var root = AppDataRoot.Explicit(path); Directory.CreateDirectory(path);
    try
    {
      var tools = Path.Combine(path, "tools");
      foreach (var kind in new[] { "codex", "bin" })
      {
        var exe = Path.Combine(tools, "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", kind, "codex.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(exe)!); File.WriteAllText(exe, "Synthetic planner fixture; never executed.");
      }
      var chat = new ChatRecord(1, new(Guid.NewGuid().ToString(), "codex", path, "Codex", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), Guid.NewGuid().ToString("N"), [], []);
      var plan = new WindowsChatLaunchPlanner(root, tools).Plan(chat);
      Assert.Contains("app-server", plan.Arguments); Assert.Contains("--stdio", plan.Arguments); Assert.DoesNotContain("exec", plan.Arguments);
      Assert.Contains("cli_auth_credentials_store=\"file\"", plan.Arguments);
      Assert.Equal(Path.Combine(path, "accounts", chat.Definition.AccountHome, "codex"), plan.Environment["CODEX_HOME"]);
    }
    finally { Directory.Delete(path, true); }
  }
  [Fact] public void MixedSessionsRemainSelectedAndRestoreChatPresentationOnRefresh()
  {
    var terminal = new SessionRecord(new(Guid.NewGuid().ToString(), "shell", @"C:\TD\sample", "Terminal"), "key", SessionState.Running);
    var chat = new ChatRecord(1, new(Guid.NewGuid().ToString(), "claude", @"C:\TD\sample", "Chat", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), "chat-key", [], []);
    var model = new ShellViewModel(); model.Sync([terminal], [chat]);
    model.Select(model.Sessions.Single(s => s.Id == chat.Definition.Id)); var selected = model.Selected;
    model.Sync([terminal], [chat with { Busy = true, Definition = chat.Definition with { Title = "New chat title" } }]);
    Assert.Equal(2, model.Sessions.Count); Assert.Same(selected, model.Selected);
    Assert.Equal(SessionPresentation.Chat, model.Selected!.Presentation); Assert.Equal("New chat title", model.Title);
    Assert.Equal("working", model.Selected.State);
  }
}
