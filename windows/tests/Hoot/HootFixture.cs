using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Threading.Channels;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Hoot.Tests;

internal sealed class State<T>(T value) : IStateStore<T>
{ public T? Load() => value; public void Save(T next) => value = next; }
internal sealed class TestAccountProvider : IAccountProvider
{
  public string Provider => "claude";
  public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fixture@example.invalid"));
  public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("No sign-in in tests.");
  public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
  public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new("fixture", "Fixture", 200000)]);
}
internal sealed class Processes : IChatProcessKeeper
{
  private readonly ConcurrentDictionary<string, Channel<ChatSignal>> channels = new();
  private readonly ConcurrentDictionary<string, long> sequence = new();
  private readonly ConcurrentDictionary<string, bool> live = new();
  private readonly ConcurrentDictionary<string, string> leaseIds = new();
  public readonly ConcurrentQueue<(ChatRecord Chat, ChatMessage Message)> Sent = new();
  public bool LoseReceipt { get; set; }
  public ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(live.GetValueOrDefault(session.Definition.Id) ? ProcessPresence.Live : ProcessPresence.Dead, session.Definition.Id));
  public ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct)
  { live[session.Definition.Id] = true; leaseIds[session.CreationKey] = session.Definition.Id; return ObserveAsync(session, ct); }
  public ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken ct)
  {
    Sent.Enqueue((chat, message));
    if (LoseReceipt) throw new IOException("Synthetic lost reply.");
    return ValueTask.FromResult(new ChatDelivery(message.ClientId, ChatMessageState.Sent));
  }
  public void Emit(string chatId, string clientId, string kind, string text = "", string id = "answer")
  {
    var n = sequence.AddOrUpdate(chatId, 1, (_, prior) => prior + 1);
    channels.GetOrAdd(chatId, _ => Channel.CreateUnbounded<ChatSignal>()).Writer.TryWrite(new(n, kind, id, text, clientId));
  }
  public ValueTask InterruptAsync(ChatRecord chat, CancellationToken ct)
  { Emit(chat.Definition.Id, chat.ActiveClientId!, "complete"); return ValueTask.CompletedTask; }
  public ValueTask AnswerAsync(ChatRecord chat, string requestId, bool allow, System.Text.Json.JsonElement input, CancellationToken ct)
  { Emit(chat.Definition.Id, chat.ActiveClientId!, "approvalResolved", allow ? "Allowed" : "Refused", requestId); return ValueTask.CompletedTask; }
  public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [EnumeratorCancellation] CancellationToken ct)
  { await foreach (var signal in channels.GetOrAdd(chat.Definition.Id, _ => Channel.CreateUnbounded<ChatSignal>()).Reader.ReadAllAsync(ct)) yield return signal; }
  public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => ValueTask.CompletedTask;
  public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
  public ValueTask QuitAsync(string lease, CancellationToken ct) { if (leaseIds.TryGetValue(lease, out var id)) live[id] = false; return ValueTask.CompletedTask; }
}
internal sealed class Handoff : IHootSessionHandoff
{
  public int Count; public bool LoseReply { get; set; }
  public ValueTask SendAsync(string clientId, string sessionId, string text, CancellationToken ct)
  { Count++; if (LoseReply) throw new IOException("Synthetic lost handoff reply."); return ValueTask.CompletedTask; }
}
internal sealed class Fixture : IAsyncDisposable
{
  public readonly string Folder = Path.Combine(Path.GetTempPath(), "td-hoot-test-" + Guid.NewGuid().ToString("N"));
  public readonly Processes Process = new(); public readonly Handoff Handoff = new();
  public readonly AccountService Accounts; public readonly ChatSessions Chats; public readonly HootService Hoot;
  public readonly IStateStore<HootState> Store;
  public readonly string AccountId = Guid.NewGuid().ToString("N");
  public Fixture(string? folder = null)
  {
    if (folder is not null) Folder = folder;
    Directory.CreateDirectory(Folder); var root = AppDataRoot.Explicit(Folder);
    Accounts = new(new State<AccountState>(new(1, [new(AccountId, "claude", "Hoot test account", "fixture@example.invalid", AccountAuthentication.Subscription, true, AccountId)], [], [])), [new TestAccountProvider()]);
    Chats = new(new ChatHistory(root), Process, Accounts); Store = HootStorage.At(root); Hoot = new(Store, Chats, Accounts, Handoff);
  }
  public async Task Ready(int after = 0)
  { await Hoot.ConfigureAsync(new("claude", AccountId, Folder, new(), RefreshMinutes: 0, RefreshAfterTurns: after)); await Hoot.StartAsync(); }
  public async Task<string> Say(string text = "Hello Hoot")
  { var id = Guid.NewGuid().ToString(); await Hoot.SayAsync(id, text); return id; }
  public void Complete(string id, string answer = "Ready")
  {
    var chat = Hoot.Read().Turns.Single(t => t.Id == id).ChatId!;
    Process.Emit(chat, id, "message", answer); Process.Emit(chat, id, "complete");
  }
  public static async Task Wait(IHoot hoot, Func<HootState, bool> condition)
  {
    var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    void Observe(HootState state) { if (condition(state)) ready.TrySetResult(); }
    hoot.Changed += Observe;
    try { Observe(hoot.Read()); await ready.Task.WaitAsync(TimeSpan.FromSeconds(8)); }
    finally { hoot.Changed -= Observe; }
  }
  public async ValueTask DisposeAsync()
  { await Hoot.DisposeAsync(); await Chats.DisposeAsync(); Directory.Delete(Folder, true); }
}
