using System.Text.Json;
using TerminalDeck.Core;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Chat.Windows.Tests;

public sealed class ChatStopTests
{
  [Fact] public async Task UnresponsiveOwnedCliStopsBeforeTheNextMessageAndResumesItsConversation()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w5-chat-stop-" + Guid.NewGuid().ToString("N")));
    Directory.CreateDirectory(root.DirectoryPath); var tools = Path.Combine(root.DirectoryPath, "tools");
    var entry = Path.Combine(tools, "node_modules", "@anthropic-ai", "claude-code", "cli.js"); Directory.CreateDirectory(Path.GetDirectoryName(entry)!);
    File.WriteAllText(entry, """
      const fs = require('fs')
      const readline = require('readline')
      const emit = row => process.stdout.write(JSON.stringify(row) + '\n')
      fs.appendFileSync('starts.jsonl', JSON.stringify({pid:process.pid,resume:process.argv.includes('--resume')}) + '\n')
      emit({type:'system',subtype:'init',session_id:'synthetic-stop-conversation'})
      readline.createInterface({input:process.stdin}).on('line',line => {
        const row = JSON.parse(line)
        if(row.type !== 'user') return
        fs.appendFileSync('writes.jsonl',JSON.stringify({id:row.uuid})+'\n')
        emit({type:'user',uuid:row.uuid,message:row.message})
        if(row.message.content[0].text === 'hold') return
        emit({type:'assistant',message:{id:row.uuid,content:[{type:'text',text:'Synthetic next answer'}]}})
        emit({type:'result',subtype:'success',is_error:false})
      })
      """);
    var host = Environment.GetEnvironmentVariable("TD_CHAT_WORKER_HOST") ?? throw new InvalidOperationException("Choose the scratch worker host.");
    var credential = KeeperCredentials.GetOrCreate(root); var processes = new WindowsChatProcessKeeper(root, host, tools, credential);
    var accounts = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [new SyntheticAccount()]);
    var account = await accounts.CreateAsync("claude", "Synthetic"); var history = new ChatHistory(root); var chats = new ChatSessions(history, processes, accounts);
    var chat = await chats.CreateAsync("claude", root.DirectoryPath, account.Id);
    try
    {
      var first = Guid.NewGuid().ToString(); var next = Guid.NewGuid().ToString(); await chats.SendAsync(chat.Definition.Id, first, "hold");
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(40));
      while (chats.Get(chat.Definition.Id).ConversationId is null) await Task.Delay(10, deadline.Token);
      var before = File.ReadAllText(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json"));
      await chats.StopAsync(chat.Definition.Id); await chats.SendAsync(chat.Definition.Id, next, "next");
      while (chats.Get(chat.Definition.Id).Events.Count(e => e.Kind == "complete") < 2) await Task.Delay(25, deadline.Token);
      Assert.Equal(new[] { first, next }, chats.Get(chat.Definition.Id).Events.Where(e => e.Kind == "complete").Select(e => e.ClientId));
      Assert.Equal("synthetic-stop-conversation", chats.Get(chat.Definition.Id).ConversationId);
      Assert.Equal(before, File.ReadAllText(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json")));
      var starts = File.ReadAllLines(Path.Combine(root.DirectoryPath, "starts.jsonl")).Select(line => JsonDocument.Parse(line).RootElement.Clone()).ToArray();
      Assert.Equal(2, starts.Length); Assert.False(starts[0].GetProperty("resume").GetBoolean()); Assert.True(starts[1].GetProperty("resume").GetBoolean());
      Assert.Equal(2, File.ReadAllLines(Path.Combine(root.DirectoryPath, "writes.jsonl")).Length);
    }
    finally
    {
      await chats.DisposeAsync();
      if (File.Exists(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json"))) await processes.QuitAsync(chat.CreationKey, default);
      await new WindowsCredentialStore(root).DeleteAsync($"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2");
      System.Security.Cryptography.CryptographicOperations.ZeroMemory(credential); Directory.Delete(root.DirectoryPath, true);
    }
  }
  private sealed class SyntheticAccount : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "synthetic@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new NotSupportedException("Synthetic accounts never sign in.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
}
