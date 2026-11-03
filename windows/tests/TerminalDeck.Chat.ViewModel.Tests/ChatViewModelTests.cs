using System.Reflection;
using System.Threading.Channels;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Chat.ViewModel.Tests;

public sealed class ChatViewModelTests
{
  [Fact] public async Task SideQuestionUsesASeparateConversationAndPreservesMainDraftAndAccount()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    backend.Record = backend.Record with { Events = [new(1, "assistant", "source", "Recorded source context")] };
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "keep the main draft"; model.SideQuestion.SetQuestion("What about this case?"); model.SideQuestion.Prepare(model.Snapshot);
    var side = await model.CreateSideQuestionAsync(default); await model.SendSideQuestionAsync(side.Definition.Id, default);
    Assert.NotEqual(model.Id, side.Definition.Id); Assert.Equal(model.Snapshot.Definition.AccountId, side.Definition.AccountId); Assert.Equal(model.Snapshot.Definition.Options, side.Definition.Options);
    Assert.Equal("keep the main draft", model.Draft); Assert.Equal(side.Definition.Id, backend.LastSendChat); Assert.Contains("What about this case?", backend.Requests.Single().Text);
    Assert.Equal("Synthetic", backend.Record.Definition.Title);
  }
  [Fact] public async Task AChangedSideQuestionCannotStartAnUnreviewedConversation()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.SideQuestion.SetQuestion("First question"); model.SideQuestion.Prepare(model.Snapshot); model.SideQuestion.SetQuestion("Changed question");
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await model.CreateSideQuestionAsync(default)); Assert.Null(backend.SideDefinition); Assert.Equal(0, backend.Sends);
  }
  [Fact] public async Task ChipUsesProviderReportedSelectionAndNeverInventsADefault()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    await using (var empty = new ChatViewModel(chats, backend.Record.Definition.Id, action => action()))
      Assert.Equal("Claude Code default model", empty.SelectedModelName); // the chip always names a real model (Asad)
    backend.Record = backend.Record with
    {
      Definition = backend.Record.Definition with { Options = new("requested-model", "high") },
      Events = [new(1, "providerInit", "init", Data: ChatProviderSnapshot.Capture("claude", backend.Record.CreationKey,
        System.Text.Json.JsonSerializer.SerializeToElement(new { model = "reported-model" })))]
    };
    await using var selected = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    Assert.Equal("reported-model", selected.SelectedModelId); Assert.Equal("reported-model", selected.SelectedModelName);
  }
  private static async Task Until(Func<bool> ready)
  { using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5)); while (!ready()) await Task.Delay(5, deadline.Token); }
  [Fact] public async Task SignInResumesTheRejectedSendOnceAndKeepsANewerDraft()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats; backend.SignedIn = false;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "original request"; await model.SendAsync();
    Assert.True(model.HasUnconfirmedSend); Assert.Empty(backend.Deliveries);
    model.Draft = "newer draft";
    model.SignInRequested = () => { backend.SignedIn = true; return Task.CompletedTask; };
    await model.SignInAsync();
    Assert.Single(backend.Deliveries); Assert.Equal("newer draft", model.Draft);
    Assert.Equal("original request", backend.Requests.Last().Text); Assert.False(model.HasUnconfirmedSend);
  }
  [Fact] public async Task CancelledSignInKeepsDraftAndDoesNotRetryTheMessage()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats; backend.SignedIn = false;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "keep this"; await model.SendAsync();
    model.SignInRequested = () => Task.CompletedTask; await model.SignInAsync();
    Assert.Equal("keep this", model.Draft); Assert.Empty(backend.Deliveries); Assert.Equal(1, backend.Sends);
  }
  [Fact] public async Task CancellingAsLoginCompletesNeverResendsThePendingMessage()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats; backend.SignedIn = false;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "keep this"; await model.SendAsync();
    model.SignInRequested = () => { backend.SignedIn = true; throw new SignInCancelledException(); };
    await model.SignInAsync();
    Assert.Equal("keep this", model.Draft); Assert.Empty(backend.Deliveries); Assert.Equal(1, backend.Sends);
  }
  [Fact] public async Task ControlUpdatesShowPendingAndDoNotOverlapOtherControlWrites()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats; backend.ControlGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    var first = model.SetOptionsAsync(new("model", "high")); Assert.True(model.ChangingControl);
    await model.SetOptionsAsync(new("other", "low")); Assert.Equal(1, backend.ControlWrites);
    backend.ControlGate.SetResult(); await first;
    Assert.False(model.ChangingControl); Assert.Equal("model", model.Snapshot.Definition.Options.Model); Assert.Contains("next message", model.ControlNotice);
  }
  [Fact] public async Task AcknowledgementDoesNotClearANewerDraftEvenWhenItsTextMatchesTheOldSend()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats; backend.LoseNextReply = true;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "first"; await model.SendAsync(); model.Draft = "changed"; model.Draft = "first";
    await model.SendAsync(); Assert.False(model.HasUnconfirmedSend); Assert.Equal("first", model.Draft); Assert.Single(backend.Deliveries);
  }
  [Fact] public async Task OversizeUtf8PromptStaysEditableAndNeverStartsASend()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    var original = string.Concat(Enumerable.Repeat("😀", 65537)); model.Draft = original; await model.SendAsync();
    Assert.Equal(original, model.Draft); Assert.False(model.HasUnconfirmedSend); Assert.Equal(0, backend.Sends); Assert.Contains("UTF-8", model.Error);
  }
  [Fact] public async Task RecallOnlyRunsAtAnEligibleCaretAndKeepsDraftOnReturn()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    backend.Record = backend.Record with { Events = [new(1, "user", "first", "first prompt")] };
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "unsent draft"; Assert.False(model.RecallPrompt(true, false)); Assert.Equal("unsent draft", model.Draft);
    Assert.True(model.RecallPrompt(true, true)); Assert.Equal("first prompt", model.Draft);
    Assert.True(model.RecallPrompt(false, true)); Assert.Equal("unsent draft", model.Draft); Assert.Equal(0, backend.Sends);
  }
  [Fact] public async Task LostSendReplyKeepsItsClientIdAndPreservesLaterDraftEdits()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats; backend.LoseNextReply = true;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "first message"; await model.SendAsync(); Assert.True(model.HasUnconfirmedSend);
    model.Draft = "a later edit"; await model.SendAsync();
    Assert.False(model.HasUnconfirmedSend); Assert.Equal("a later edit", model.Draft);
    Assert.Equal(backend.Requests[0].Id, backend.Requests[1].Id); Assert.Equal("first message", backend.Requests[1].Text); Assert.Single(backend.Deliveries);
    await model.SendAsync(); Assert.Equal(2, backend.Deliveries.Count); Assert.NotEqual(backend.Requests[0].Id, backend.Requests[2].Id); Assert.Equal("", model.Draft);
  }
  [Fact] public async Task ReconnectRestartsABrokenWatchAndKeepsReceivingLaterUpdates()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    backend.BreakFirstWatch.TrySetResult(); await Until(() => model.Error is not null);
    await model.ReconnectAsync(); await Until(() => backend.Watches == 2);
    backend.Updates.Writer.TryWrite(backend.Record with { Definition = backend.Record.Definition with { Title = "Later update" } });
    await Until(() => model.Snapshot.Definition.Title == "Later update"); Assert.Null(model.Error);
  }
  [Fact] public async Task SendRefreshesItsResultEvenBeforeTheNextWatchSnapshot()
  {
    var chats = DispatchProxy.Create<IChatSessions, ChatWatchProxy>(); var backend = (ChatWatchProxy)chats;
    await using var model = new ChatViewModel(chats, backend.Record.Definition.Id, action => action());
    model.Draft = "hello"; await model.SendAsync();
    Assert.Equal("Sent", model.Snapshot.Definition.Title); Assert.Equal("", model.Draft); Assert.Equal(1, backend.Sends);
  }
}

public class ChatWatchProxy : DispatchProxy
{
  public ChatRecord Record = new(1, new(Guid.NewGuid().ToString(), "claude", Path.GetTempPath(), "Synthetic", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), Guid.NewGuid().ToString("N"), [], []);
  public TaskCompletionSource BreakFirstWatch { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public Channel<ChatRecord> Updates { get; } = Channel.CreateUnbounded<ChatRecord>();
  public int Watches;
  public int Sends;
  public bool LoseNextReply;
  public bool SignedIn = true;
  public TaskCompletionSource? ControlGate;
  public int ControlWrites;
  public ChatDefinition? SideDefinition;
  public string? LastSendChat;
  public List<(string Id, string Text)> Requests { get; } = [];
  public HashSet<string> Deliveries { get; } = [];
  protected override object? Invoke(MethodInfo? method, object?[]? arguments)
  {
    return method?.Name switch
    {
      "get_DataRoot" => null,
      nameof(IChatSessions.Get) => Record,
      nameof(IChatSessions.ReadAsync) => ValueTask.FromResult(Record),
      nameof(IChatSessions.CreateAsync) when arguments![0] is ChatDefinition definition => Created(definition),
      nameof(IChatSessions.Accounts) => new AccountProfile[] { new(Record.Definition.AccountId, "claude", "Synthetic", null, AccountAuthentication.Subscription, SignedIn, Record.Definition.AccountHome) },
      nameof(IChatSessions.WatchAsync) => Watch((CancellationToken)arguments![1]!),
      nameof(IChatSessions.ReconnectAsync) => ValueTask.CompletedTask,
      nameof(IChatSessions.SetOptionsAsync) => SetOptions((ChatOptions)arguments![1]!),
      nameof(IChatSessions.SendAsync) => Sent((string)arguments![0]!, (string)arguments[1]!, (string)arguments[2]!),
      _ => throw new NotSupportedException("Unexpected chat test operation.")
    };
  }
  private async ValueTask SetOptions(ChatOptions options)
  {
    ControlWrites++; if (ControlGate is not null) await ControlGate.Task;
    Record = Record with { Definition = Record.Definition with { Options = options } };
  }
  private ValueTask<ChatRecord> Created(ChatDefinition definition)
  {
    SideDefinition = definition;
    return ValueTask.FromResult(new ChatRecord(1, definition, Guid.NewGuid().ToString("N"), [], []));
  }
  private ValueTask Sent(string chatId, string id, string text)
  {
    LastSendChat = chatId; Sends++; Requests.Add((id, text));
    if (!SignedIn) return ValueTask.FromException(new SignInRequiredException(new(Record.Definition.AccountId, "claude", "Synthetic", null, AccountAuthentication.Subscription, false, Record.Definition.AccountHome)));
    Deliveries.Add(id);
    if (LoseNextReply) { LoseNextReply = false; return ValueTask.FromException(new IOException("Synthetic lost reply.")); }
    if (chatId == Record.Definition.Id) Record = Record with { Definition = Record.Definition with { Title = "Sent" } }; return ValueTask.CompletedTask;
  }
  private async IAsyncEnumerable<ChatRecord> Watch([System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
  {
    var number = Interlocked.Increment(ref Watches); yield return Record;
    if (number == 1) { await BreakFirstWatch.Task.WaitAsync(ct); throw new IOException("Synthetic broken connection."); }
    await foreach (var record in Updates.Reader.ReadAllAsync(ct)) yield return record;
  }
}
