using System.Collections.Concurrent;
using System.Text.Json;
using TerminalDeck.Core;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Chat.Windows.Tests;

public sealed class ChatWindowsTests
{
  private static ChatRecord Chat(AppDataRoot root, string provider = "claude")
  {
    var account = Guid.NewGuid().ToString("N"); Directory.CreateDirectory(root.DirectoryPath);
    return new(1, new(Guid.NewGuid().ToString(), provider, root.DirectoryPath, "Synthetic chat", account, account, new()), Guid.NewGuid().ToString("N"), [], []);
  }
  private static AppDataRoot Scratch() => AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w5-chat-" + Guid.NewGuid().ToString("N")));
  [Fact] public void PlannerUsesVerifiedNativePathsPipesAndPerAccountHome()
  {
    var root = Scratch(); var chat = Chat(root); var planner = new WindowsChatLaunchPlanner(root, @"C:\TD\tools\ai");
    try
    {
      var launch = planner.Plan(chat); Assert.EndsWith("claude.exe", launch.Executable, StringComparison.OrdinalIgnoreCase);
      Assert.Contains("stream-json", launch.Arguments); Assert.Contains("--replay-user-messages", launch.Arguments);
      Assert.Equal(Path.Combine(root.DirectoryPath, "accounts", chat.Definition.AccountHome, "claude"), launch.Environment["CLAUDE_CONFIG_DIR"]);
      Assert.False(launch.Environment.ContainsKey("ANTHROPIC_API_KEY")); Assert.False(launch.Environment.ContainsKey("CLAUDE_CODE_OAUTH_TOKEN"));
      var codexChat = chat with { Definition = chat.Definition with { Provider = "codex", AccountHome = Guid.NewGuid().ToString("N"), Options = new("proof-model", "high") }, ConversationId = "proof-conversation" };
      var message = new ChatMessage("proof-client", "Prompt text belongs on the protocol pipe.", []);
      var codex = planner.Plan(codexChat, message);
      Assert.True(planner.CodexAppServer);
      Assert.EndsWith(@"bin\codex.exe", codex.Executable, StringComparison.OrdinalIgnoreCase);
      // Models, effort, resume identity and prompts are sent over app-server's
      // protocol. Only the isolated credential setting belongs before stdio.
      Assert.Equal(new[] { "-c", "cli_auth_credentials_store=\"file\"", "app-server", "--stdio" }, codex.Arguments);
      Assert.Equal(Path.Combine(root.DirectoryPath, "accounts", codexChat.Definition.AccountHome, "codex"), codex.Environment["CODEX_HOME"]);
      Assert.False(codex.Environment.ContainsKey("OPENAI_API_KEY")); Assert.False(codex.Environment.ContainsKey("CLAUDE_CONFIG_DIR"));
      Assert.Equal(codexChat.Definition.Cwd, codex.WorkingDirectory);
      var compatibility = new WindowsChatLaunchPlanner(root, @"C:\TD\tools\ai", codexAppServer: false).Plan(codexChat, message);
      Assert.Equal(codex.Executable, compatibility.Executable); Assert.Equal(codex.Environment["CODEX_HOME"], compatibility.Environment["CODEX_HOME"]);
      Assert.Equal(new[] { "-c", "cli_auth_credentials_store=\"file\"", "exec", "--json", "--color", "never", "--model", "proof-model", "-c", "model_reasoning_effort=\"high\"", "--sandbox", "read-only", "resume", "proof-conversation", "-" }, compatibility.Arguments);
      Assert.DoesNotContain(message.Text, compatibility.Arguments);
      var gemini = planner.Plan(chat with { Definition = chat.Definition with { Provider = "gemini" } }); Assert.Contains("--acp", gemini.Arguments); Assert.True(gemini.Environment.ContainsKey("GEMINI_CLI_HOME"));
    }
    finally { Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task SavedWorkerEventsResumeAtTheirCursorWithoutALiveProcess()
  {
    var root = Scratch(); var chat = Chat(root);
    Directory.CreateDirectory(ChatWorkerPaths.DirectoryFor(root));
    var signals = new[] { new ChatSignal(1, "conversation", Text: "exact"), new ChatSignal(2, "message", "m", "saved answer"), new ChatSignal(3, "complete") };
    var path = ChatWorkerPaths.FileFor(root, chat.CreationKey, ".journal.json");
    File.WriteAllBytes(path, JsonSerializer.SerializeToUtf8Bytes(new ChatWorkerJournal([], signals, 3, "exact")));
    try
    {
      var keeper = new WindowsChatProcessKeeper(root, "unused.exe", "unused-tools", new byte[32]);
      var events = await keeper.ReadSavedSignalsAsync(chat, 1, default);
      Assert.Equal(new long[] { 2, 3 }, events.Select(e => e.Sequence)); Assert.Equal("saved answer", events[0].Text);
      Assert.Empty(await keeper.ReadSavedSignalsAsync(chat, 3, default));
      // The completed read leaves no handle blocking the next replacement.
      File.Move(path, path + ".old");
    }
    finally { Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task RealSignedOutClaudePrintBecomesPlainSentenceAndSavedMediaFreeHistory()
  {
    var proofRoot = Environment.GetEnvironmentVariable("TD_CHAT_PROOF_ROOT") ?? throw new InvalidOperationException("Choose the isolated proof root.");
    var root = AppDataRoot.Explicit(proofRoot); var chat = Chat(root); var history = new ChatHistory(root); history.Save(chat);
    var launch = new WindowsChatLaunchPlanner(root, @"C:\TD\tools\ai").Plan(chat);
    launch = launch with { Arguments = [.. launch.Arguments, "--setting-sources", "user", "--settings", "{\"disableAllHooks\":true}", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"] };
    var signals = new ConcurrentQueue<ChatSignal>();
    await using var cli = new ChatCliConnection(chat, history, launch, signal => { signals.Enqueue(signal); return ValueTask.CompletedTask; });
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75)); await cli.StartAsync(timeout.Token);
    var message = new ChatMessage(Guid.NewGuid().ToString(), "Reply with the word hello.", [], ChatMessageState.Failed);
    await cli.SendAsync(message, timeout.Token);
    while (!signals.Any(s => s.Kind == "error")) await Task.Delay(25, timeout.Token);
    var problem = signals.First(s => s.Kind == "error").Text; Assert.Equal("Not signed in to Claude. Sign in to continue.", problem);
    history.Save(chat with { Messages = [message], Problem = problem, Events = signals.Select((s, i) => new ChatEvent(i + 1, s.Kind, s.Id, s.Text, s.ClientId, s.Data, DateTimeOffset.UtcNow)).ToArray() });
    File.WriteAllText(Path.Combine(root.DirectoryPath, "signed-out-proof.json"), JsonSerializer.Serialize(new { chatId = chat.Definition.Id, problem, cliLaunched = true, signedIn = false }));
  }
  [Fact] public async Task DetachedPipeWorkerSurvivesOwnerRecreationAndSameClientIdWritesOnlyOnce()
  {
    var root = Scratch(); var chat = Chat(root); var history = new ChatHistory(root); history.Save(chat);
    var tools = Path.Combine(root.DirectoryPath, "tools"); var entry = Path.Combine(tools, "node_modules", "@anthropic-ai", "claude-code", "cli.js"); Directory.CreateDirectory(Path.GetDirectoryName(entry)!);
    File.WriteAllText(entry, """
      const readline = require('readline')
      const emit = row => process.stdout.write(JSON.stringify(row) + '\n')
      emit({type:'system', subtype:'init', session_id:'synthetic-conversation'})
      readline.createInterface({input:process.stdin}).on('line', line => {
        const row = JSON.parse(line)
        if (row.type === 'user') {
          emit({type:'user', uuid:row.uuid, message:row.message})
          emit({type:'assistant', message:{id:row.uuid, content:[{type:'text',text:'Synthetic reply'}]}})
          emit({type:'result',subtype:'success',is_error:false})
        }
      })
      """);
    var host = Environment.GetEnvironmentVariable("TD_CHAT_WORKER_HOST") ?? throw new InvalidOperationException("Choose the scratch worker host.");
    var credential = KeeperCredentials.GetOrCreate(root);
    var first = new WindowsChatProcessKeeper(root, host, tools, credential);
    try
    {
      Assert.Equal(ProcessPresence.Live, (await first.EnsureAsync(ChatSessions.Session(chat), false, default)).Presence);
      var identityPath = ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json"); var before = File.ReadAllText(identityPath);
      var client = new ChatMessage(Guid.NewGuid().ToString(), "hello", []); Assert.Equal(ChatMessageState.Sent, (await first.SendAsync(chat, client, default)).State);
      // Recreate the owner and its adapter. The independent worker and CLI stay.
      var second = new WindowsChatProcessKeeper(root, host, tools, credential);
      Assert.Equal(ProcessPresence.Live, (await second.EnsureAsync(ChatSessions.Session(chat), false, default)).Presence);
      Assert.Equal(ChatMessageState.Sent, (await second.SendAsync(chat, client, default)).State); Assert.Equal(before, File.ReadAllText(identityPath));
      using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)); var seen = new List<ChatSignal>();
      await foreach (var signal in second.WatchAsync(chat, 0, timeout.Token)) { seen.Add(signal); if (signal.Kind == "complete") break; }
      Assert.Single(seen, s => s.Kind == "message");
      var journal = JsonSerializer.Deserialize<ChatWorkerJournal>(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".journal.json")))!;
      Assert.Single(journal.Receipts); Assert.Single(journal.Signals, s => s.Kind == "message");
    }
    finally
    {
      await first.QuitAsync(chat.CreationKey, default);
      var identity = JsonSerializer.Deserialize<ChatWorkerIdentity>(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json")))!;
      using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
      while (true)
      {
        try { using var owned = System.Diagnostics.Process.GetProcessById(identity.Pid); if (owned.HasExited || owned.StartTime.ToUniversalTime().Ticks != identity.StartedUtcTicks) break; }
        catch (ArgumentException) { break; }
        await Task.Delay(50, timeout.Token);
      }
      await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2");
      System.Security.Cryptography.CryptographicOperations.ZeroMemory(credential); Directory.Delete(root.DirectoryPath, true);
    }
  }
}
