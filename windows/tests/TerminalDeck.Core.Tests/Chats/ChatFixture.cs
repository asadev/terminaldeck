using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class ChatFixture : IAsyncDisposable
{
  public AppDataRoot Root { get; } = AppDataRoot.Explicit(Path.Combine(OperatingSystem.IsMacOS() && Path.GetTempPath().StartsWith("/var/", StringComparison.Ordinal) ? "/private" + Path.GetTempPath() : Path.GetTempPath(), "td-chat-test-" + Guid.NewGuid().ToString("N")));
  public FakeAccountProvider Provider { get; } = new("claude");
  public AccountService Accounts { get; }
  public ChatHistory History { get; }
  public PipeFakeKeeper Keeper { get; }
  public ChatSessions Chats { get; private set; }
  public AccountProfile Account { get; private set; } = null!;
  public ChatRecord Chat { get; private set; } = null!;
  public ChatFixture(TimeProvider? clock = null)
  {
    Accounts = new(new MemoryState<AccountState>(), [Provider]); History = new(Root); Keeper = new(History);
    Chats = new(History, Keeper, Accounts, clock);
  }
  public async Task InitializeAsync(bool signedIn = true)
  {
    Directory.CreateDirectory(Root.DirectoryPath);
    // Older chat tests expect asking; the new-chat default itself is covered in UmerPermissionAndEnterTests.
    new TerminalDeck.Core.Settings.GeneralSettings(new JsonStateStore<TerminalDeck.Core.Settings.GeneralPreferences>(Root, "general-settings")).Save(new(DefaultPermission: TerminalDeck.Core.Mcp.AiPermissionMode.Ask));
    Account = await Accounts.CreateAsync("claude", "Synthetic");
    if (signedIn) { Provider.Statuses[Account.Id] = new(true, "synthetic@example.test"); await Accounts.RefreshAsync(Account.Id); }
    Chat = await Chats.CreateAsync("claude", Root.DirectoryPath, Account.Id);
    // Older chat tests expect no model choice; the app-wide model fill is covered in UmerAccountsTests.
    if (signedIn) { await Chats.SetOptionsAsync(Chat.Definition.Id, new()); Chat = Chats.Get(Chat.Definition.Id); }
  }
  public async Task RestartAsync()
  { await Chats.DisposeAsync(); Chats = new(History, Keeper, Accounts); await Chats.RecoverAsync(); }
  public static async Task UntilAsync(Func<bool> predicate)
  {
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    while (!predicate()) await Task.Delay(10, timeout.Token);
  }
  public async ValueTask DisposeAsync()
  {
    await Chats.DisposeAsync(); await Keeper.DisposeAsync();
    if (Directory.Exists(Root.DirectoryPath)) Directory.Delete(Root.DirectoryPath, true);
  }
}

// The process is a real synthetic CLI over redirected stdin/stdout. Its owner
// stays alive while ChatSessions is disposed/recreated, like the Windows worker.
public sealed class PipeFakeKeeper(IChatHistory history) : IChatProcessKeeper, IAsyncDisposable
{
  private sealed class Worker(ChatRecord chat)
  {
    public ChatRecord Chat { get; } = chat;
    public ChatCliConnection? Connection { get; set; }
    public List<ChatSignal> Signals { get; } = [];
    public Dictionary<string, ChatDelivery> Receipts { get; } = [];
    public Dictionary<Guid, Channel<ChatSignal>> Watchers { get; } = [];
    public object Gate { get; } = new();
  }
  private readonly Dictionary<string, Worker> workers = [];
  public int Starts { get; private set; }
  public ConcurrentDictionary<string, int> Writes { get; } = new();
  public bool LoseNextReply { get; set; }
  public bool HoldInterrupt { get; set; }
  public ProcessPresence? PresenceOverride { get; set; }
  private static string FixturePath()
  {
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null)
    {
      var path = Path.Combine(directory.FullName, "tests", "TerminalDeck.Core.Tests", "Chats", "fake-claude.py");
      if (File.Exists(path)) return path;
      directory = directory.Parent;
    }
    throw new IOException("The synthetic CLI fixture was not found.");
  }
  public ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(
    PresenceOverride ?? (workers.ContainsKey(session.CreationKey) ? ProcessPresence.Live : ProcessPresence.Dead), session.CreationKey));
  public async ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct)
  {
    if (workers.ContainsKey(session.CreationKey)) return new(ProcessPresence.Live, session.CreationKey);
    var chat = history.Load(session.Definition.Id)!; var worker = new Worker(chat); workers[session.CreationKey] = worker;
    var launch = new ProcessLaunch("/usr/bin/python3", ["-u", FixturePath(), chat.ConversationId ?? "synthetic-" + chat.Definition.Id], new Dictionary<string, string> { ["PATH"] = "/usr/bin:/bin", ["PYTHONIOENCODING"] = "utf-8" }, chat.Definition.Cwd);
    worker.Connection = new(chat, history, launch, signal =>
    {
      lock (worker.Gate)
      {
        signal = signal with { Sequence = worker.Signals.Count + 1 }; worker.Signals.Add(signal);
        foreach (var watcher in worker.Watchers.Values) watcher.Writer.TryWrite(signal);
      }
      return ValueTask.CompletedTask;
    });
    Starts++; await worker.Connection.StartAsync(ct); return new(ProcessPresence.Live, session.CreationKey);
  }
  public async ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken ct)
  {
    var worker = workers[chat.CreationKey];
    lock (worker.Gate) if (worker.Receipts.TryGetValue(message.ClientId, out var existing)) return existing;
    Writes.AddOrUpdate(message.ClientId, 1, (_, count) => count + 1);
    await worker.Connection!.SendAsync(message, ct);
    var receipt = new ChatDelivery(message.ClientId, ChatMessageState.Sent); lock (worker.Gate) worker.Receipts[message.ClientId] = receipt;
    if (LoseNextReply) { LoseNextReply = false; throw new IOException("Synthetic lost acknowledgment."); }
    return receipt;
  }
  public ValueTask AnswerAsync(ChatRecord chat, string requestId, bool allow, JsonElement input, CancellationToken ct) => workers[chat.CreationKey].Connection!.AnswerAsync(requestId, allow, input, ct);
  public ValueTask InterruptAsync(ChatRecord chat, CancellationToken ct) => HoldInterrupt ? ValueTask.CompletedTask : workers[chat.CreationKey].Connection!.InterruptAsync(ct);
  public async ValueTask QuitAsync(string lease, CancellationToken ct)
  { if (workers.Remove(lease, out var worker)) await worker.Connection!.DisposeAsync(); }
  public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new NotSupportedException();
  public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
  public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
  {
    var worker = workers[chat.CreationKey]; var channel = Channel.CreateUnbounded<ChatSignal>(); var id = Guid.NewGuid(); ChatSignal[] prior;
    lock (worker.Gate) { worker.Watchers[id] = channel; prior = worker.Signals.Where(s => s.Sequence > after).ToArray(); }
    try
    {
      foreach (var signal in prior) yield return signal;
      await foreach (var signal in channel.Reader.ReadAllAsync(ct)) yield return signal;
    }
    finally { lock (worker.Gate) worker.Watchers.Remove(id); }
  }
  public async ValueTask DisposeAsync() { foreach (var worker in workers.Values) await worker.Connection!.DisposeAsync(); workers.Clear(); }
}
