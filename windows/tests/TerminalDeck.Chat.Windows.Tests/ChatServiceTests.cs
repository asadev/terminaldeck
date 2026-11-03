using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Chat.Windows.Tests;

public sealed class ChatServiceTests
{
  [Fact] public async Task ImageReadDoesNotDependOnTheCallingUiSynchronizationContext()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w5-chat-image-" + Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(root.DirectoryPath);
    var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
    var accounts = new AccountService(new State<AccountState>(), [new SignedOut()]); var account = await accounts.CreateAsync("claude", "Synthetic");
    await using var core = new ChatSessions(new ChatHistory(root), new NoProcesses(), accounts); var chat = await core.CreateAsync("claude", root.DirectoryPath, account.Id);
    var image = await core.AddImageAsync(chat.Definition.Id, "synthetic.png", "image/png", new byte[] { 1, 2, 3, 4 }, 1, 1);
    var server = new ChatSessionsPipeServer(root, core, credential).RunAsync(stop.Token);
    try
    {
      var client = await WindowsChatSessionsClient.ConnectAsync(root, credential); var context = new QueuedContext();
      var read = Task.Run(() => { SynchronizationContext.SetSynchronizationContext(context); try { return client.ReadImage(chat.Definition.Id, image); } finally { SynchronizationContext.SetSynchronizationContext(null); } });
      var completed = await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(3))); var independent = completed == read;
      if (!independent) { for (var i = 0; i < 100 && !read.IsCompleted; i++) { context.Drain(); await Task.Delay(10); } }
      Assert.True(independent, "Image reads must not block the UI waiting for that same UI thread."); Assert.Equal(new byte[] { 1, 2, 3, 4 }, await read);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); Directory.Delete(root.DirectoryPath, true); }
  }
  private sealed class QueuedContext : SynchronizationContext
  {
    private readonly System.Collections.Concurrent.ConcurrentQueue<(SendOrPostCallback Callback, object? State)> work = new();
    public override void Post(SendOrPostCallback callback, object? state) => work.Enqueue((callback, state));
    public void Drain() { while (work.TryDequeue(out var item)) item.Callback(item.State); }
  }
  [Fact] public async Task AppCanCreateItsFirstChatWithoutReadingAccountHomes()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w5-chat-first-" + Guid.NewGuid().ToString("N")));
    Directory.CreateDirectory(root.DirectoryPath); var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
    var accounts = new AccountService(new State<AccountState>(), [new SignedOut()]); var account = await accounts.CreateAsync("claude", "Synthetic");
    await using var core = new ChatSessions(new ChatHistory(root), new NoProcesses(), accounts);
    var server = new ChatSessionsPipeServer(root, core, credential).RunAsync(stop.Token);
    try
    {
      var client = await WindowsChatSessionsClient.ConnectAsync(root, credential); Assert.Empty(client.List());
      var chat = await client.CreateAsync("claude", root.DirectoryPath, account.Id);
      Assert.Equal(account.HomeId, chat.Definition.AccountHome); Assert.Single(client.List()); Assert.Single(client.Accounts(chat.Definition.Id));
      await client.RenameAsync(chat.Definition.Id, "Named over the app pipe");
      Assert.Equal("Named over the app pipe", core.Get(chat.Definition.Id).Definition.Title);
      Assert.Equal("Named over the app pipe", (await client.ReadAsync(chat.Definition.Id)).Definition.Title);
      await client.SetPermissionAsync(chat.Definition.Id, AiPermissionMode.Plan);
      Assert.Equal(AiPermissionMode.Plan, core.Get(chat.Definition.Id).Definition.PermissionMode);
      Assert.Equal(AiPermissionMode.Plan, client.Get(chat.Definition.Id).Definition.PermissionMode);
      await Assert.ThrowsAsync<InvalidOperationException>(async () => await client.SetPermissionAsync(chat.Definition.Id, (AiPermissionMode)999));
      Assert.Equal(AiPermissionMode.Plan, core.Get(chat.Definition.Id).Definition.PermissionMode);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public async Task AppPipeAuthenticatesWatchesPlainSignInStateAndTransfersMediaOutsideJson()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w5-chat-service-" + Guid.NewGuid().ToString("N")));
    Directory.CreateDirectory(root.DirectoryPath); var credential = RandomNumberGenerator.GetBytes(32);
    using var stop = new CancellationTokenSource();
    var accounts = new AccountService(new State<AccountState>(), [new SignedOut()]); var account = await accounts.CreateAsync("claude", "Synthetic");
    var history = new ChatHistory(root); await using var core = new ChatSessions(history, new NoProcesses(), accounts);
    var chat = await core.CreateAsync("claude", root.DirectoryPath, account.Id); var server = new ChatSessionsPipeServer(root, core, credential).RunAsync(stop.Token);
    try
    {
      await Assert.ThrowsAnyAsync<IOException>(async () => await WindowsChatSessionsClient.ConnectAsync(root, RandomNumberGenerator.GetBytes(32)));
      var client = await WindowsChatSessionsClient.ConnectAsync(root, credential);
      Assert.Single(client.List()); Assert.Equal(account.Id, Assert.Single(client.Accounts(chat.Definition.Id)).Id);
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
      await using (var watcher = client.WatchAsync(chat.Definition.Id, deadline.Token).GetAsyncEnumerator(deadline.Token))
      {
        Assert.True(await watcher.MoveNextAsync()); var next = watcher.MoveNextAsync();
        await client.SendAsync(chat.Definition.Id, Guid.NewGuid().ToString(), "hello"); Assert.True(await next);
        while (watcher.Current.Problem is null) Assert.True(await watcher.MoveNextAsync());
        Assert.Equal("Not signed in to Claude. Sign in to continue.", watcher.Current.Problem);
      }
      var image = await client.AddImageAsync(chat.Definition.Id, "synthetic.png", "image/png", new byte[] { 1, 2, 3, 4 }, 1, 1);
      Assert.Equal(new byte[] { 1, 2, 3, 4 }, client.ReadImage(chat.Definition.Id, image));
      var path = Path.Combine(root.DirectoryPath, "chats", Guid.Parse(chat.Definition.Id).ToString("N"), "chat.json");
      Assert.DoesNotContain("AQIDBA==", File.ReadAllText(path));
      await client.ReconnectAsync(chat.Definition.Id); Assert.False(client.Get(chat.Definition.Id).Busy);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); Directory.Delete(root.DirectoryPath, true); }
  }
  private sealed class State<T> : IStateStore<T> { private T? value; public T? Load() => value; public void Save(T state) => value = state; }
  private sealed class SignedOut : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(false, null));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
  private sealed class NoProcesses : IChatProcessKeeper
  {
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Dead));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct) => throw new InvalidOperationException("The signed-out fixture cannot start a CLI.");
    public ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken ct) => throw new InvalidOperationException();
    public ValueTask AnswerAsync(ChatRecord chat, string requestId, bool allow, JsonElement data, CancellationToken ct) => throw new InvalidOperationException();
    public ValueTask InterruptAsync(ChatRecord chat, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask QuitAsync(string lease, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new InvalidOperationException();
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { await Task.CompletedTask; yield break; }
  }
}
