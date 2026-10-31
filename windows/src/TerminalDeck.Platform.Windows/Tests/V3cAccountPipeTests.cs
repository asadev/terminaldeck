using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class V3cAccountPipeTests
{
  [Fact]
  public async Task AppPipePlansAndSwitchesTheSameSavedConversationWithoutSending()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-v3c-account-pipe-" + Guid.NewGuid().ToString("N")));
    Directory.CreateDirectory(root.DirectoryPath); var credential = RandomNumberGenerator.GetBytes(32);
    using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    var accounts = new AccountService(new State<AccountState>(), [new SignedInProvider()]);
    var first = await accounts.CreateAsync("claude", "First"); var second = await accounts.CreateAsync("claude", "Second");
    await accounts.RefreshAsync(first.Id); await accounts.RefreshAsync(second.Id);
    var history = new ChatHistory(root); var id = Guid.NewGuid().ToString(); var conversation = Guid.NewGuid().ToString();
    history.Save(new(1, new(id, "claude", root.DirectoryPath, "Fixture", first.Id, first.HomeId, new()), Guid.NewGuid().ToString("N"), [new(1, "message", "saved", "Previous reply")], [], ConversationId: conversation));
    string Transcript(AccountProfile account) => Path.Combine(root.DirectoryPath, "accounts", account.HomeId, "claude", "projects", "fixture", conversation + ".jsonl");
    Directory.CreateDirectory(Path.GetDirectoryName(Transcript(first))!);
    File.WriteAllText(Transcript(first), JsonSerializer.Serialize(new { sessionId = conversation, cwd = root.DirectoryPath }) + "\n");
    await using var chats = new ChatSessions(history, new NoProcesses(), accounts);
    var server = new ChatSessionsPipeServer(root, chats, credential).RunAsync(stop.Token);
    try
    {
      var client = await WindowsChatSessionsClient.ConnectAsync(root, credential, stop.Token);
      Assert.True(await client.CanSwitchAccountAsync(id, second.Id, stop.Token));
      Assert.Equal(first.Id, client.Get(id).Definition.AccountId); Assert.False(File.Exists(Transcript(second)));
      await client.SetAccountAsync(id, second.Id, stop.Token);
      Assert.Equal(second.Id, client.Get(id).Definition.AccountId); Assert.Equal(second.HomeId, client.Get(id).Definition.AccountHome);
      Assert.Equal(conversation, client.Get(id).ConversationId); Assert.Equal("Previous reply", Assert.Single(client.Get(id).Events).Text);
      Assert.Equal(File.ReadAllText(Transcript(first)), File.ReadAllText(Transcript(second)));
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); Directory.Delete(root.DirectoryPath, true); }
  }
  private sealed class State<T> : IStateStore<T> { private T? value; public T? Load() => value; public void Save(T state) => value = state; }
  private sealed class SignedInProvider : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, account.Id + "@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("No sign-in in this fixture.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
  private sealed class NoProcesses : IChatProcessKeeper
  {
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Dead));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct) => throw new InvalidOperationException("Switching cannot start a CLI.");
    public ValueTask QuitAsync(string lease, CancellationToken ct) => throw new InvalidOperationException("No worker is running.");
    public ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken ct) => throw new InvalidOperationException("Switching cannot send a message.");
    public ValueTask AnswerAsync(ChatRecord chat, string id, bool allow, JsonElement input, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask InterruptAsync(ChatRecord chat, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { await Task.CompletedTask; yield break; }
  }
}
