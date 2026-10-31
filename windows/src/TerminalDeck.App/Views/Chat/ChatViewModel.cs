using System.ComponentModel;
using System.Runtime.CompilerServices;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views.Chat;

public sealed class ChatViewModel : INotifyPropertyChanged, IAsyncDisposable
{
  private readonly IChatSessions chats;
  private readonly AccountService? accountModels;
  private Task<IReadOnlyList<ProviderModel>>? modelRead;
  private readonly Action<Action> dispatch;
  private readonly CancellationTokenSource lifetime = new();
  private Task watching;
  private readonly ChatDraftBuffer draftBuffer;
  private readonly Action draftChanged;
  private readonly Action<string> controlRequested;
  private readonly Action sideChanged;
  public ChatSideQuestionState SideQuestion => draftBuffer.SideQuestion;
  public event Action<string>? ControlRequested;
  public string? RequestedModel { get; private set; }
  public bool ReadingModels { get; private set; }
  public string SelectedModelId => ChatProviderSnapshot.Read(Snapshot).Model ?? Snapshot.Definition.Options.Model;
  // Asad's rule: the chip always names a real model, never a blank prompt. With no
  // explicit choice it shows the AI's own default (greyed by the page, with why).
  public string SelectedModelName => AvailableModels.FirstOrDefault(m => m.Id == SelectedModelId)?.Name ?? (SelectedModelId.Length > 0 ? TerminalDeck.Core.Accounts.ModelNames.Display(SelectedModelId, AvailableModels) : DefaultModelName);
  public bool ModelIsFallback => SelectedModelId.Length == 0 && AvailableModels.FirstOrDefault(m => m.IsDefault) is null;
  public string DefaultModelName => AvailableModels.FirstOrDefault(m => m.IsDefault)?.Name ?? AvailableModels.FirstOrDefault()?.Name ??
    TerminalDeck.Core.Agents.AgentSeats.ProviderName(Snapshot.Definition.Provider) + " default model";
  public string EffectiveEffort => Snapshot.Definition.Options.Effort is { Length: > 0 } chosen && chosen != "auto" ? chosen :
    (AvailableModels.FirstOrDefault(m => m.Id == SelectedModelId) ?? AvailableModels.FirstOrDefault(m => m.IsDefault))?.Efforts?.Contains("xhigh") == true ? "xhigh" :
    Snapshot.Definition.Provider == "codex" ? "medium" : "high";
  public IReadOnlyList<ProviderModel> AvailableModels { get; private set; } = [];
  public bool ChangingControl { get; private set; }
  public string? ControlNotice { get; private set; }
  private long noticeRevision;
  private ChatMessage? unconfirmedSend;
  private long unconfirmedDraftRevision;
  public bool HasUnconfirmedSend => unconfirmedSend is not null;
  private readonly ChatPromptRecall recall = new();
  public string Id { get; }
  public ChatRecord Snapshot { get; private set; }
  public IReadOnlyList<ChatRecord> PastChats => chats.List();
  public IReadOnlyList<ChatRow> Rows { get; private set; } = [];
  public IReadOnlyList<ChatMessage> Pending => Snapshot.Messages.Where(m => m.State == ChatMessageState.Queued).ToArray();
  public List<ChatMedia> Attachments { get; } = [];
  public string? Error { get; private set; }
  public bool Sending { get; private set; }
  public string Draft { get => draftBuffer.Read().Text; set => draftBuffer.Edit(value); }
  public ChatEditorCopy? EditorCopy => draftBuffer.EditorCopy;
  private ChatDraftEditorCopies EditorCopies => new(chats.DataRoot ?? throw new InvalidOperationException("This chat has no private editor folder."));
  public async ValueTask<ChatEditorCopy> PrepareEditorCopyAsync(string? text = null, ChatEditorSource? source = null) => EditorCopies.Prepare(await chats.ReadAsync(Id, lifetime.Token), draftBuffer, text, source);
  public async ValueTask ImportEditorCopyAsync() => EditorCopies.Import(await chats.ReadAsync(Id, lifetime.Token), draftBuffer);
  public void DiscardEditorCopy() => EditorCopies.Discard(draftBuffer);
  public long DraftRevision => draftBuffer.Read().Revision;
  public void ApplyDraft(string text, long expectedRevision) => draftBuffer.Apply(text, expectedRevision);
  public string AccountName => chats.Accounts(Id).FirstOrDefault(a => a.Id == Snapshot.Definition.AccountId) is { } account ? account.SignedIn ? account.Email ?? account.Name : "Not signed in" : "Not signed in";
  public IReadOnlyList<AccountProfile> Accounts => chats.Accounts(Id);
  public event PropertyChangedEventHandler? PropertyChanged;
  public ChatViewModel(IChatSessions chats, string id, Action<Action> dispatch, AccountService? accountModels = null)
  {
    this.accountModels = accountModels;
    this.chats = chats; this.dispatch = dispatch; Id = id;
    draftBuffer = ChatDraftWorkspace.Open(id); draftChanged = () => dispatch(() => Changed(nameof(Draft))); draftBuffer.Changed += draftChanged;
    sideChanged = () => dispatch(() => Changed(nameof(SideQuestion))); draftBuffer.SideQuestion.Changed += sideChanged;
    controlRequested = control => dispatch(() => { if (!lifetime.IsCancellationRequested) ControlRequested?.Invoke(control); }); draftBuffer.ControlRequested += controlRequested;
    Snapshot = chats.Get(id); AvailableModels = accountModels?.CachedModels(Snapshot.Definition.AccountId)?.Models ?? []; Refresh(Snapshot); watching = WatchAsync(); _ = ModelsAsync();
  }
  private async Task WatchAsync()
  {
    try { await foreach (var chat in chats.WatchAsync(Id, lifetime.Token)) dispatch(() => Refresh(chat)); }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    catch (IOException) { dispatch(() => { Error = "This chat needs to reconnect. Your messages are kept."; Changed(nameof(Error)); }); }
  }
  private void Refresh(ChatRecord chat)
  { var accountChanged = Snapshot.Definition.AccountId != chat.Definition.AccountId;
    Snapshot = chat;
    if (accountChanged) { AvailableModels = []; _ = ModelsAsync(); }
    if (unconfirmedSend is { } attempt && chat.Messages.Any(m => m.ClientId == attempt.ClientId)) Acknowledge(attempt);
    Rows = ChatProjection.Rows(chat); ApplyPendingPermission(); Changed(nameof(Snapshot)); Changed(nameof(Rows)); Changed(nameof(Pending)); Changed(nameof(AccountName)); }
  private void Changed([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new(property));
  public async Task RunAsync(Func<ValueTask> action)
  {
    Error = null; Changed(nameof(Error));
    try { await action(); Refresh(chats.Get(Id)); }
    catch (SignInRequiredException)
    { Error = ChatErrors.NotSignedIn(Snapshot.Definition.Provider); Changed(nameof(Error)); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or TimeoutException)
    { Error = ex.Message.StartsWith("Sign in to ", StringComparison.Ordinal) ? ChatErrors.NotSignedIn(Snapshot.Definition.Provider) : ex is TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : ex is IOException ? "This chat could not connect. Your messages are kept." : ex.Message; Changed(nameof(Error)); }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
  }
  public async Task SendAsync()
  {
    if (PendingPermission is { } due && IsIdle(Snapshot) && !ChangingControl)
    { PendingPermission = null; Changed(nameof(PendingPermission)); await ChangeControlAsync(() => chats.SetPermissionAsync(Id, due, lifetime.Token), "Permission mode changed."); }
    if (Sending || unconfirmedSend is null && string.IsNullOrWhiteSpace(Draft) && Attachments.Count == 0) return;
    if (unconfirmedSend is null && Attachments.Sum(a => a.Bytes) > 8 * 1024 * 1024)
    { await RunAsync(() => throw new ArgumentException("Keep this message’s images under 8 MB in total.")); return; }
    try { ChatText.ValidatePrompt(unconfirmedSend?.Text ?? Draft); }
    catch (ArgumentException ex) { Error = ex.Message; Changed(nameof(Error)); return; }
    Sending = true; Changed(nameof(Sending));
    if (unconfirmedSend is null) { var source = draftBuffer.Read(); unconfirmedDraftRevision = source.Revision; unconfirmedSend = new(Guid.NewGuid().ToString(), source.Text, Attachments.ToArray()); }
    var attempt = unconfirmedSend;
    Changed(nameof(HasUnconfirmedSend));
    try
    {
      await RunAsync(async () =>
      {
        await chats.SendAsync(Id, attempt.ClientId, attempt.Text, attempt.Media, lifetime.Token);
        Acknowledge(attempt);
      });
      if (Error == ChatErrors.OriginalFilesNeeded && !chats.Get(Id).Messages.Any(m => m.ClientId == attempt.ClientId))
      { unconfirmedSend = null; Changed(nameof(HasUnconfirmedSend)); }
    }
    finally { Sending = false; Changed(nameof(Sending)); }
  }
  private void Acknowledge(ChatMessage attempt)
  {
    if (unconfirmedSend?.ClientId != attempt.ClientId) return;
    unconfirmedSend = null;
    if (DraftRevision == unconfirmedDraftRevision && Draft == attempt.Text) Draft = "";
    Attachments.RemoveAll(a => attempt.Media.Contains(a)); Changed(nameof(Attachments)); Changed(nameof(HasUnconfirmedSend));
  }
  public Task RefreshRecordedAsync() => RunAsync(async () => { _ = await chats.ReadAsync(Id, lifetime.Token); });
  public Task ContinueWithoutResendingAsync() => RunAsync(() => chats.ContinueWithoutResendingAsync(Id, lifetime.Token));
  public Task EndAsync() => RunAsync(() => chats.EndAsync(Id, lifetime.Token));
  public Task StopAsync() => RunAsync(() => chats.StopAsync(Id, lifetime.Token));
  public Task RetryAsync() => RunAsync(() => chats.RetryAsync(Id, lifetime.Token));
  public Task ReconnectAsync() => RunAsync(async () =>
  {
    await chats.ReconnectAsync(Id, lifetime.Token);
    if (watching.IsCompleted) watching = WatchAsync(); _ = ModelsAsync();
  });
  public void ClearError() { Error = null; Changed(nameof(Error)); }
  public Task SendNowAsync(string clientId) => RunAsync(() => chats.SendNowAsync(Id, clientId, lifetime.Token));
  public Task EditAsync(string clientId, string text) => RunAsync(() => chats.EditQueuedAsync(Id, clientId, text, lifetime.Token));
  public Task RemoveAsync(string clientId) => RunAsync(() => chats.RemoveQueuedAsync(Id, clientId, lifetime.Token));
  public Task AnswerAsync(string requestId, bool allow) => RunAsync(() => chats.AnswerAsync(Id, requestId, allow, lifetime.Token));
  public Task SetOptionsAsync(ChatOptions options)
  { RequestedModel = options.Model; Changed(nameof(RequestedModel)); return ChangeControlAsync(() => chats.SetOptionsAsync(Id, options, lifetime.Token), "Saved choices apply on the next message."); }
  public bool RecallPrompt(bool previous, bool eligible)
  {
    if (!eligible || Sending || HasUnconfirmedSend) return false;
    var text = recall.Move(previous, Draft, ChatText.Prompts(Snapshot));
    if (text is null) return false;
    Draft = text; return true;
  }
  public bool IsRecalledPrompt => recall.IsRecalled(Draft);
  public Task RenameAsync(string title) => ChangeControlAsync(() => chats.RenameAsync(Id, title, lifetime.Token), "Session name saved.");
  // A mode picked while the AI is busy waits and is applied the moment the chat is idle,
  // so it takes effect from the next message without cutting off the running answer.
  public AiPermissionMode? PendingPermission { get; private set; }
  public AiPermissionMode ShownPermission => PendingPermission ?? Snapshot.Definition.PermissionMode;
  private bool IsIdle(ChatRecord c) => !Sending && !c.Ended && !c.Busy && !c.Stopping &&
    !c.Messages.Any(m => m.State == ChatMessageState.Queued || ChatSessions.Unconfirmed(c, m)) &&
    !c.Events.Any(e => e.Kind == "approval" && !c.Events.Any(a => a.Kind == "approvalResolved" && a.Id == e.Id));
  public Task SetPermissionAsync(AiPermissionMode mode)
  {
    if (IsIdle(Snapshot) && !ChangingControl) { PendingPermission = null; return ChangeControlAsync(() => chats.SetPermissionAsync(Id, mode, lifetime.Token), "Saved permissions apply on the next message."); }
    PendingPermission = mode == Snapshot.Definition.PermissionMode ? null : mode; Changed(nameof(PendingPermission));
    ControlNotice = PendingPermission is null ? null : "Permission mode applies from your next message."; Changed(nameof(ControlNotice)); return Task.CompletedTask;
  }
  private void ApplyPendingPermission()
  {
    if (PendingPermission is not { } mode || ChangingControl || !IsIdle(Snapshot)) return;
    PendingPermission = null; Changed(nameof(PendingPermission)); _ = ChangeControlAsync(() => chats.SetPermissionAsync(Id, mode, lifetime.Token), "Permission mode changed.");
  }
  public Task SetAccountAsync(string accountId) => ChangeControlAsync(() => chats.SetAccountAsync(Id, accountId, lifetime.Token), "Account saved for this chat.");
  private async Task ChangeControlAsync(Func<ValueTask> action, string success)
  {
    if (ChangingControl) return;
    var revision = ++noticeRevision; ControlNotice = null; ChangingControl = true; Changed(nameof(ChangingControl));
    try
    {
      await RunAsync(action);
      if (Error is null) { ControlNotice = success; Changed(nameof(ControlNotice)); _ = ExpireNoticeAsync(revision); }
    }
    finally { ChangingControl = false; Changed(nameof(ChangingControl)); }
  }
  private async Task ExpireNoticeAsync(long revision)
  {
    try { await Task.Delay(TimeSpan.FromSeconds(4), lifetime.Token); dispatch(() => { if (noticeRevision == revision) { ControlNotice = null; Changed(nameof(ControlNotice)); } }); }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
  }
  public Func<Task>? SignInRequested { get; set; }
  public async Task SignInAsync()
  {
    await RunAsync(async () =>
    {
      if (SignInRequested is { } signIn) await signIn();
      else await chats.SignInAsync(Id, lifetime.Token);
    });
    if (Error is null && chats.Accounts(Id).Any(a => a.Id == Snapshot.Definition.AccountId && a.SignedIn) && unconfirmedSend is not null) await SendAsync();
  }
  public Task<IReadOnlyList<ProviderModel>> ModelsAsync() => modelRead is { IsCompleted: false } running ? running : modelRead = ReadModelsAsync();
  private async Task<IReadOnlyList<ProviderModel>> ReadModelsAsync()
  {
    ReadingModels = true; Changed(nameof(ReadingModels));
    try
    {
      var accountId = Snapshot.Definition.AccountId;
      IReadOnlyList<ProviderModel> result = [];
      await RunAsync(async () => { result = accountModels is null ? await chats.ModelsAsync(Id, lifetime.Token) : (await accountModels.ModelsAsync(accountId, cancellationToken: lifetime.Token)).Models; });
      if (Snapshot.Definition.AccountId != accountId) return [];
      AvailableModels = result; Changed(nameof(AvailableModels)); return result;
    }
    finally { ReadingModels = false; Changed(nameof(ReadingModels)); }
  }
  public async Task AddImageAsync(string name, string mimeType, byte[] bytes, int width, int height)
  {
    await RunAsync(async () => { Attachments.Add(await chats.AddImageAsync(Id, name, mimeType, bytes, width, height, lifetime.Token)); Changed(nameof(Attachments)); });
  }
  public ValueTask<byte[]> ReadImageAsync(ChatMedia media) => chats.ReadImageAsync(Id, media, lifetime.Token);
  public void RemoveAttachment(string id) { Attachments.RemoveAll(a => a.Id == id); Changed(nameof(Attachments)); }
  public async ValueTask DisposeAsync()
  { draftBuffer.SideQuestion.Changed -= sideChanged; draftBuffer.ControlRequested -= controlRequested; draftBuffer.Changed -= draftChanged; lifetime.Cancel(); await watching; lifetime.Dispose(); }
}
