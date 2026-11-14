using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Tests.Chats;

// Stopping a chat (Stop, update handover, reconnect) ends its Claude process; it
// must not land between Claude's sign-in renewal call and its save (saba-pc, 1 Nov).
[Collection("Windows chat")]
public sealed class ChatStopRenewalTests
{
  [Fact]
  public async Task AStoppedClaudeChatWaitsForItsSignInRenewalThenEnds()
  {
    if (OperatingSystem.IsWindows()) return; // the fixture runs python3 from /usr/bin
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var config = Path.Combine(f.Root.DirectoryPath, "claude-home"); var held = Directory.CreateDirectory(Path.Combine(config, ".oauth_refresh.lock"));
    var file = Path.Combine(f.Root.DirectoryPath, "busy-fixture.py");
    File.WriteAllText(file, "import time\nwhile True:\n  time.sleep(1)\n");
    var chat = f.Chat with { Definition = f.Chat.Definition with { Provider = "claude" } };
    var launch = new TerminalDeck.Core.Platform.ProcessLaunch(TestPython.Executable, ["-u", file], TestPython.Environment(("CLAUDE_CONFIG_DIR", config)), f.Root.DirectoryPath);
    var cli = new ChatCliConnection(chat, f.History, launch, _ => ValueTask.CompletedTask);
    await cli.StartAsync();
    var stopping = cli.DisposeAsync().AsTask();
    await Task.Delay(TimeSpan.FromSeconds(1.5));
    Assert.False(stopping.IsCompleted);
    Assert.True(cli.Alive);
    held.Delete();
    await stopping.WaitAsync(TimeSpan.FromSeconds(10));
  }
}
