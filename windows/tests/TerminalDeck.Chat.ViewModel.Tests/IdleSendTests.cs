using System.Reflection;
using System.Text.Json;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Chat.ViewModel.Tests;

// Exercise the real send service through the page model. A quiet worker watch
// deliberately leaves completion only in its journal, as after a detached watch.
public sealed class IdleSendTests
{
  [Theory]
  [InlineData(false, false)]
  [InlineData(true, false)]
  [InlineData(true, true)]
  public async Task IdleSendNeedsNoSendNowEvenWithStaleBusyOrLostReceipt(bool staleBusy, bool uncertain)
  {
    await using var fixture = new Fixture(staleBusy, uncertain);
    await using var model = new ChatViewModel(fixture.Chats, fixture.Record.Definition.Id, a => a());
    model.Draft = "next request"; await model.SendAsync();
    Assert.Null(model.Error); Assert.Null(model.Snapshot.Problem); Assert.Empty(model.Pending); Assert.Empty(model.Draft);
    Assert.Single(fixture.Worker.Writes); Assert.Equal("next request", fixture.Worker.Writes.Single().Text);
    Assert.True(model.Snapshot.Busy);
  }
  [Fact] public async Task RealActiveTurnHoldsUntilCompletionAndThenDrainsOnce()
  {
    await using var fixture = new Fixture(true, false, completed: false);
    await using var model = new ChatViewModel(fixture.Chats, fixture.Record.Definition.Id, a => a());
    model.Draft = "follow up"; await model.SendAsync();
    Assert.Null(model.Error); Assert.Single(model.Pending); Assert.Empty(fixture.Worker.Writes);
    fixture.Worker.Journal = [new(1, "complete", ClientId: "previous")];
    await fixture.Chats.ReconnectAsync(model.Id);
    Assert.Single(fixture.Worker.Writes); Assert.Equal("follow up", fixture.Worker.Writes.Single().Text);
  }
  [Fact] public async Task UnresolvedDeliveryShowsAnErrorInsteadOfAnIdleSendNowCard()
  {
    await using var fixture = new Fixture(false, true, completed: false);
    await using var model = new ChatViewModel(fixture.Chats, fixture.Record.Definition.Id, a => a());
    model.Draft = "keep this draft"; await model.SendAsync();
    Assert.NotNull(model.Error); Assert.Empty(model.Pending); Assert.Empty(fixture.Worker.Writes);
    Assert.Equal("keep this draft", model.Draft);
  }
  [Theory]
  [InlineData("Commander", "C")]
  [InlineData("Alex Smith", "AS")]
  [InlineData("  ", "?")]
  [InlineData("Élodie Khan", "ÉK")]
  public void AgentFallbackUsesItsOwnInitials(string name, string expected) => Assert.Equal(expected, AgentPictures.Initials(name));

  private sealed class Fixture : IAsyncDisposable
  {
    public ChatRecord Record { get; }
    public ChatSessions Chats { get; }
    public TurnWorkerProxy Worker { get; }
    public Fixture(bool busy, bool uncertain, bool completed = true)
    {
      var account = new AccountProfile(Guid.NewGuid().ToString("N"), "claude", "Test", null, AccountAuthentication.Subscription, true, Guid.NewGuid().ToString("N"));
      Record = new(1, new(Guid.NewGuid().ToString(), "claude", Path.GetTempPath(), "Synthetic", account.Id, account.HomeId, new()), Guid.NewGuid().ToString("N"), [],
        busy || uncertain ? [new("previous", "old request", [], uncertain ? ChatMessageState.Uncertain : ChatMessageState.Sent)] : [], Busy: busy, ActiveClientId: busy ? "previous" : null);
      var keeper = DispatchProxy.Create<ITurnWorker, TurnWorkerProxy>(); Worker = (TurnWorkerProxy)keeper;
      if (busy && completed) Worker.Journal = [new(1, "complete", ClientId: "previous")];
      var accounts = new AccountService(new State(new(1, [account], [], [])), [new SignedInProvider()]);
      Chats = new(new History(Record), keeper, accounts);
    }
    public ValueTask DisposeAsync() => Chats.DisposeAsync();
  }
  private sealed class State(AccountState value) : IStateStore<AccountState>
  { public AccountState? Load() => value; public void Save(AccountState next) => value = next; }
  private sealed class SignedInProvider : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "synthetic@example.test"));
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
  }
  private sealed class History(ChatRecord record) : IChatHistory
  {
    public IReadOnlyList<ChatRecord> List() => [record];
    public ChatRecord? Load(string id) => record;
    public void Save(ChatRecord next) => record = next;
    public ValueTask<ChatMedia> AddImageAsync(string id, string name, string mime, ReadOnlyMemory<byte> bytes, int width, int height, CancellationToken ct) => throw new NotSupportedException();
    public byte[] ReadMedia(string id, ChatMedia media) => throw new NotSupportedException();
    public JsonElement ExternalizeData(string id, JsonElement data) => data;
  }
}
public interface ITurnWorker : IChatProcessKeeper, IChatRecoveryJournal { }
public class TurnWorkerProxy : DispatchProxy
{
  public ChatSignal[] Journal = [];
  public List<ChatMessage> Writes { get; } = [];
  protected override object? Invoke(MethodInfo? method, object?[]? args) => method?.Name switch
  {
    nameof(IChatRecoveryJournal.ReadSavedSignalsAsync) => ValueTask.FromResult<IReadOnlyList<ChatSignal>>(Journal.Where(s => s.Sequence > (long)args![1]!).ToArray()),
    nameof(IChatProcessKeeper.WatchAsync) => Quiet((CancellationToken)args![2]!),
    nameof(ISessionProcessKeeper.ObserveAsync) or nameof(ISessionProcessKeeper.EnsureAsync) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Live, ((SessionRecord)args![0]!).CreationKey)),
    nameof(IChatProcessKeeper.SendAsync) => Send((ChatMessage)args![1]!),
    _ => throw new NotSupportedException(method?.Name)
  };
  private ValueTask<ChatDelivery> Send(ChatMessage message)
  {
    if (message.ClientId == "previous") return ValueTask.FromResult(new ChatDelivery(message.ClientId, ChatMessageState.Uncertain));
    Writes.Add(message); return ValueTask.FromResult(new ChatDelivery(message.ClientId, ChatMessageState.Sent));
  }
  private static async IAsyncEnumerable<ChatSignal> Quiet([System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
  { await Task.Delay(Timeout.Infinite, ct); yield break; }
}
