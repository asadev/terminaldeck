using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading.Channels;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Chats;

public sealed partial class ChatSessions(IChatHistory history, IChatProcessKeeper processes, AccountService accounts, TimeProvider? time = null) : IChatSessions, IAsyncDisposable
{
  public AppDataRoot? DataRoot => history.DataRoot;
  private readonly SemaphoreSlim gate = new(1);
  private readonly ConcurrentDictionary<string, ChatRecord> chats = new(history.List().ToDictionary(c => c.Definition.Id));
  private readonly Dictionary<string, Task> followers = [];
  private readonly ConcurrentDictionary<Guid, (string Id, Channel<ChatRecord> Channel)> watchers = new();
  private readonly CancellationTokenSource lifetime = new();
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  public IReadOnlyList<ChatRecord> List() => chats.Values.OrderBy(c => c.Events.FirstOrDefault()?.At).ToArray();
  public ChatRecord Get(string id) => chats.GetValueOrDefault(id) ?? throw new KeyNotFoundException("This chat was not found.");
  public async ValueTask<ChatRecord> CreateAsync(string provider, string folder, string accountId, ChatOptions? options = null, CancellationToken cancellationToken = default)
  {
    var account = accounts.Get(accountId);
    if (account.Provider != provider) throw new ArgumentException("Choose an account for this coding AI.");
    var definition = new ChatDefinition(Guid.NewGuid().ToString(), provider, folder, ChatText.FolderTitle(folder), account.Id, account.HomeId, options ?? new(), PermissionMode: TerminalDeck.Core.Settings.GeneralSettings.NewChatPermission(history.DataRoot, provider));
    return await CreateAsync(definition, cancellationToken: cancellationToken);
  }
  public ValueTask<ChatRecord> CreateAsync(ChatDefinition definition, string? conversationId = null, CancellationToken cancellationToken = default) =>
    CreateAsync(definition, customTitle: false, conversationId, cancellationToken);
  // customTitle: the person named this chat (New session "Name"), so the first message never renames it.
  public async ValueTask<ChatRecord> CreateAsync(ChatDefinition definition, bool customTitle, string? conversationId = null, CancellationToken cancellationToken = default)
  {
    // A chat with no model of its own starts on the app-wide choice, so every chip
    // names a real model and level from the first moment (never "Default").
    if (conversationId is null) definition = definition with { Options = TerminalDeck.Core.Settings.LaunchDefaults.Fill(definition.Provider, definition.Options, history.DataRoot) };
    definition.Validate(); var account = accounts.Get(definition.AccountId);
    if (account.Provider != definition.Provider || account.HomeId != definition.AccountHome) throw new ArgumentException("Choose the account home belonging to this coding AI.");
    if (conversationId is { Length: > 128 } || conversationId?.Any(char.IsControl) == true) throw new ArgumentException("Choose a valid saved conversation.");
    var chat = new ChatRecord(1, definition, Guid.NewGuid().ToString("N"), [], [], ConversationId: conversationId, HasCustomTitle: customTitle);
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (chats.TryGetValue(definition.Id, out var existing))
      { if (existing.Definition != definition) throw new InvalidOperationException("That chat identity belongs to another request."); return existing; }
      Save(chat); return chat;
    }
    finally { gate.Release(); }
  }
  public async ValueTask SendAsync(string id, string clientId, string text, ChatMedia[]? media = null, CancellationToken cancellationToken = default)
  {
    ValidateMessage(clientId, text, media ?? []);
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); RequireActive(chat); var existing = chat.Messages.FirstOrDefault(m => m.ClientId == clientId);
      if (existing is not null)
      {
        if (existing.Text != text || !existing.Media.SequenceEqual(media ?? [])) throw new InvalidOperationException("This message id already belongs to another message.");
        if (Unconfirmed(chat, existing) && (await processes.ObserveAsync(Session(chat), cancellationToken)).Presence == ProcessPresence.Live)
        {
          // Reconcile an existing worker receipt only. Never create a fresh
          // worker to replay an ambiguously delivered message with the old id.
          var receipt = await processes.SendAsync(chat, existing, cancellationToken);
          if (receipt.ClientId != existing.ClientId) throw new IOException("The chat returned another message’s receipt.");
          Save(Replace(Get(id), existing with { State = receipt.State }));
        }
        return;
      }
      // The worker may have finished while its watch was detached or behind.
      // Read its durable turn events before deciding to hold another message.
      if (chat.Busy || chat.Messages.Any(m => Unconfirmed(chat, m)))
      {
        await RecoverChatAsync(chat, cancellationToken, sending: true);
        chat = Get(id);
      }
      if (chat.Messages.Any(m => Unconfirmed(chat, m)))
        throw new InvalidOperationException("Check the previous message’s delivery before sending again. Reconnect, or keep it without resending.");
      // Signing in again can move an account's login to a newer folder (the old one is
      // signed out). An idle chat follows its account there before this turn, keeping
      // its conversation, so chats and terminals of one account use the same login.
      if (!chat.Busy && !chat.Stopping && !chat.Messages.Any(m => m.State == ChatMessageState.Queued || Unconfirmed(chat, m)))
      {
        AccountProfile? owner = null;
        try { owner = accounts.Get(chat.Definition.AccountId); } catch (Exception ex) when (ex is ArgumentException or KeyNotFoundException or InvalidOperationException) { }
        if (owner is { SignedIn: true } && owner.Provider == chat.Definition.Provider && owner.HomeId != chat.Definition.AccountHome)
        {
          try
          {
            if (chat.ConversationId is not null) await Switches.SwitchAsync(id, owner.Id, cancellationToken);
            else { await RetireWorkerAsync(chat, cancellationToken); Save(chat with { Definition = chat.Definition with { AccountId = owner.Id, AccountHome = owner.HomeId }, CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0 }); }
          }
          catch (Exception ex) when (ex is IOException or InvalidOperationException && !cancellationToken.IsCancellationRequested) { }
          chat = Get(id);
        }
      }
      if (Get(id).Definition.Provider != "claude" && (media ?? []).Any(m => m.MimeType == "application/pdf")) throw new ArgumentException("This coding AI connection does not accept PDF attachments. Choose Claude for this document.");
      long imageBytes = 0;
      foreach (var item in media ?? [])
      {
        try { imageBytes += history.ReadMedia(id, item).Length; }
        catch (Exception ex) when (ex is IOException or ArgumentException) { throw new ChatFilesNeededException(); }
        if (imageBytes > 8 * 1024 * 1024) throw new ArgumentException("Keep this message’s images under 8 MB in total.");
      }
      var message = new ChatMessage(clientId, text, media ?? []);
      if (chat.Messages.Count(m => m.State == ChatMessageState.Queued) >= 100) throw new InvalidOperationException("Send or remove a queued message first.");
      if (TerminalDeck.Core.Settings.GeneralSettings.ShouldAutoName(DataRoot, chat.HasCustomTitle, chat.Messages.Length))
      {
        var title = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        title = new string(title.Select(c => char.IsControl(c) ? ' ' : c).ToArray());
        if (title.Length > 80) title = title[..80];
        if (title.Length > 0) chat = chat with { Definition = chat.Definition with { Title = title } };
      }
      chat = chat with { Messages = [.. chat.Messages, message], Paused = false, Problem = null }; Save(chat);
      if (!chat.Busy && !chat.Messages.Any(m => Unconfirmed(chat, m))) await DispatchAsync(chat, message, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask SendNowAsync(string id, string clientId, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); RequireActive(chat); var message = Queued(chat, clientId);
      // Move exactly this id to the front; identical text is never an identity.
      Save(chat with { Messages = [message, .. chat.Messages.Where(m => m.ClientId != clientId)], Paused = false, Stopping = chat.Busy });
      if (chat.Busy && !chat.Stopping) await processes.InterruptAsync(chat, cancellationToken);
      else if (!chat.Busy) await DispatchAsync(Get(id), message, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask EditQueuedAsync(string id, string clientId, string text, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { var chat = Get(id); RequireActive(chat); var message = Queued(chat, clientId); ValidateMessage(clientId, text, message.Media); Save(Replace(chat, message with { Text = text })); }
    finally { gate.Release(); }
  }
  public async ValueTask RemoveQueuedAsync(string id, string clientId, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { var chat = Get(id); RequireActive(chat); var message = Queued(chat, clientId); Save(Replace(chat, message with { State = ChatMessageState.Removed })); }
    finally { gate.Release(); }
  }
  public async ValueTask AnswerAsync(string id, string requestId, bool allow, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id);
      if (chat.Stopping) throw new InvalidOperationException("This answer is stopping. Wait before answering its request.");
      var request = chat.Events.LastOrDefault(e => e.Kind == "approval" && e.Id == requestId) ?? throw new InvalidOperationException("That approval is no longer waiting.");
      if (chat.Events.Any(e => e.Kind is "approvalResolved" or "approvalSending" && e.Id == requestId)) throw new InvalidOperationException("That approval has already been answered.");
      var data = request.Data ?? JsonSerializer.SerializeToElement(new { });
      await processes.AnswerAsync(chat, requestId, allow, data, cancellationToken);
      Save(Add(Get(id), "approvalResolved", requestId, allow ? "Allowed" : "Refused"));
    }
    finally { gate.Release(); }
  }
  public async ValueTask StopAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id);
      Save(chat with { Paused = true, Stopping = chat.Busy, WaitingSince = null });
      if (chat.Busy && !chat.Stopping)
      {
        try { await processes.InterruptAsync(chat, cancellationToken); }
        catch
        { Save(Get(id) with { Stopping = false, Problem = "This chat needs to reconnect before it can stop." }); throw; }
      }
      else if (!chat.Busy) Save(Add(Get(id), "stopped", Guid.NewGuid().ToString("N"), "Stopped. Queued messages are kept."));
    }
    finally { gate.Release(); }
  }
  public async ValueTask ContinueWithoutResendingAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); RequireActive(chat);
      if (chat.Busy || chat.Messages.Any(m => m.State == ChatMessageState.Dispatching)) throw new InvalidOperationException("Reconnect and wait for this answer to stop first.");
      var uncertain = chat.Messages.Where(m => Unconfirmed(chat, m)).ToArray();
      if (uncertain.Length == 0) throw new InvalidOperationException("There is no uncertain message to keep without resending.");
      await RetireWorkerAsync(chat, cancellationToken);
      if ((await processes.ObserveAsync(Session(chat), cancellationToken)).Presence != ProcessPresence.Dead)
        throw new IOException("The previous chat worker has not stopped yet.");
      foreach (var message in uncertain) chat = Add(chat, "uncertaintyAcknowledged", message.ClientId, "Kept without resending. Delivery remains uncertain.", message.ClientId);
      chat = chat with { CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0, Paused = false, Stopping = false, Problem = null }; Save(chat);
      if (chat.Messages.FirstOrDefault(m => m.State == ChatMessageState.Queued) is { } queued) await DispatchAsync(chat, queued, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask EndAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); if (chat.Ended) return;
      // End is durable only after the owned worker and its CLI have retired.
      await RetireWorkerAsync(chat, cancellationToken);
      if ((await processes.ObserveAsync(Session(chat), cancellationToken)).Presence != ProcessPresence.Dead)
        throw new IOException("The chat has not finished closing. Reconnect and try End chat again.");
      chat = chat with { Ended = true, Busy = false, ActiveClientId = null, Stopping = false, Paused = true, WaitingSince = null,
        Messages = chat.Messages.Select(m => m.State == ChatMessageState.Dispatching ? m with { State = ChatMessageState.Uncertain } : m).ToArray() };
      Save(Add(chat, "ended", Guid.NewGuid().ToString("N"), "Chat ended. History is kept."));
    }
    finally { gate.Release(); }
  }
  public async ValueTask RetryAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); RequireActive(chat);
      var failed = chat.Busy ? chat.Messages.FirstOrDefault(m => m.ClientId == chat.ActiveClientId) : chat.Messages.LastOrDefault(m => m.State == ChatMessageState.Failed);
      if (failed is null || failed.State is ChatMessageState.Uncertain or ChatMessageState.Dispatching) throw new InvalidOperationException("There is no failed message to retry. An uncertain message must be checked first.");
      if (!HaveOriginalFiles(chat, failed)) { Save(chat with { Problem = ChatErrors.OriginalFilesNeeded }); return; }
      var alreadyStopping = chat.Stopping;
      var message = failed with { ClientId = Guid.NewGuid().ToString(), State = ChatMessageState.Queued };
      chat = chat with { Messages = [message, .. chat.Messages], Problem = null, Paused = false, Stopping = chat.Busy }; Save(chat);
      if (chat.Busy && !alreadyStopping) await processes.InterruptAsync(chat, cancellationToken);
      else if (!chat.Busy) await DispatchAsync(chat, message, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public byte[] ReadImage(string id, ChatMedia media) => history.ReadMedia(Get(id).Definition.Id, media);
  public async ValueTask SetOptionsAsync(string id, ChatOptions options, CancellationToken cancellationToken = default)
  {
    var chat = Get(id);
    if (chat.Definition.Provider == "gemini" && options.Effort is not ("" or "auto")) throw new ArgumentException("Gemini does not offer an effort choice in this chat mode.");
    var models = options.Model.Length == 0 ? [] : await ModelsAsync(id, cancellationToken);
    if (options.Model.Length > 0 && !models.Any(m => m.Id == options.Model)) throw new ArgumentException("Choose a model offered by this account.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      chat = Get(id); RequireIdle(chat);
      var definition = chat.Definition with { Options = options }; definition.Validate();
      await RetireWorkerAsync(chat, cancellationToken); Save(chat with { Definition = definition, CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0 });
    }
    finally { gate.Release(); }
  }
  public async ValueTask SetAccountAsync(string id, string accountId, CancellationToken cancellationToken = default)
  {
    var account = await accounts.RequireSignedInAsync(accountId, cancellationToken);
    await gate.WaitAsync(cancellationToken);
    try
    {
      await RecoverAccountSwitchesAsync(cancellationToken);
      var chat = Get(id); RequireIdle(chat);
      if (account.Provider != chat.Definition.Provider) throw new ArgumentException("Choose an account for this coding AI.");
      if (account.Id == chat.Definition.AccountId && account.HomeId == chat.Definition.AccountHome) return;
      if (chat.ConversationId is not null)
      {
        await Switches.SwitchAsync(id, account.Id, cancellationToken);
        return;
      }
      await RetireWorkerAsync(chat, cancellationToken);
      Save(chat with { Definition = chat.Definition with { AccountId = account.Id, AccountHome = account.HomeId, Options = new() }, CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0 });
    }
    finally { gate.Release(); }
  }
  public async ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string id, CancellationToken cancellationToken = default) =>
    (await accounts.ModelsAsync(Get(id).Definition.AccountId, cancellationToken: cancellationToken)).Models;
  public IReadOnlyList<AccountProfile> Accounts(string id) => accounts.List(Get(id).Definition.Provider);
  public ValueTask SignInAsync(string id, CancellationToken cancellationToken = default) => accounts.SignInAsync(Get(id).Definition.AccountId, Get(id).Definition.Cwd, cancellationToken);
  public ValueTask<ChatMedia> AddImageAsync(string id, string name, string mimeType, ReadOnlyMemory<byte> bytes, int width, int height, CancellationToken cancellationToken = default) =>
    history.AddImageAsync(id, name, mimeType, bytes, width, height, cancellationToken);

  private async ValueTask DispatchAsync(ChatRecord chat, ChatMessage message, CancellationToken ct)
  {
    var id = chat.Definition.Id;
    try
    {
      await RecoverAccountSwitchesAsync(ct);
      chat = Get(id);
      if (!HaveOriginalFiles(chat, message))
      { Save(Replace(chat, message with { State = ChatMessageState.Failed }) with { Problem = ChatErrors.OriginalFilesNeeded, Busy = false, ActiveClientId = null, WaitingSince = null }); return; }
      // A signed-out account gives the same plain sentence as the CLI parser.
      await accounts.RequireSignedInAsync(chat.Definition.AccountId, ct);
      var observation = await processes.EnsureAsync(Session(chat), chat.ConversationId is not null, ct);
      if (observation.Presence != ProcessPresence.Live) throw new IOException("This chat is waiting to reconnect.");
      Follow(chat);
      message = message with { State = ChatMessageState.Dispatching };
      if (!chat.Events.Any(e => e.Kind == "user" && e.ClientId == message.ClientId)) chat = Add(chat, "user", message.ClientId, message.Text, message.ClientId);
      chat = Replace(chat, message) with { Busy = true, ActiveClientId = message.ClientId, Problem = null, WaitingSince = clock.GetUtcNow(), Stopping = false }; Save(chat);
      ChatDelivery receipt;
      try { receipt = await processes.SendAsync(chat, message, ct); }
      catch
      {
        Save(Replace(Get(id), message with { State = ChatMessageState.Uncertain }) with { Problem = "This message may have reached the coding AI. Reconnect to check it; it will not be sent twice." });
        throw;
      }
      if (receipt.ClientId != message.ClientId) throw new IOException("The chat returned another message's receipt.");
      Save(Replace(Get(id), message with { State = receipt.State }) with
      { Problem = receipt.State is ChatMessageState.Uncertain or ChatMessageState.Dispatching ? "This message may have reached the coding AI. Reconnect to check it; it will not be sent twice." : null });
      _ = NoAnswerAsync(id, message.ClientId, chat.WaitingSince!.Value);
    }
    catch (SignInRequiredException)
    { Save(Replace(Get(id), message with { State = ChatMessageState.Failed }) with { Busy = false, ActiveClientId = null, Problem = ChatErrors.NotSignedIn(chat.Definition.Provider), WaitingSince = null }); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException && !ct.IsCancellationRequested)
    {
      var current = Get(id);
      if (current.Messages.First(m => m.ClientId == message.ClientId).State != ChatMessageState.Uncertain)
        Save(Replace(current, message with { State = ChatMessageState.Failed }) with { Busy = false, ActiveClientId = null, WaitingSince = null, Problem = ex is TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : "This chat could not connect. Retry when the coding AI is ready." });
    }
  }
  public ValueTask ReconnectAsync(string id, CancellationToken cancellationToken = default) => RecoverSelectedAsync([Get(id)], cancellationToken);
  public ValueTask RecoverAsync(CancellationToken cancellationToken = default) => RecoverSelectedAsync(List(), cancellationToken);
  private async ValueTask RecoverSelectedAsync(IReadOnlyList<ChatRecord> selected, CancellationToken cancellationToken)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      await RecoverAccountSwitchesAsync(cancellationToken);
      foreach (var original in selected) await RecoverChatAsync(original, cancellationToken);
    }
    finally { gate.Release(); }
  }
  // Caller holds gate, including sends: a completion cannot race this decision.
  private async ValueTask RecoverChatAsync(ChatRecord original, CancellationToken cancellationToken, bool sending = false)
  {
    var chat = Get(original.Definition.Id);
    if (chat.Ended) return;
    if (processes is IChatRecoveryJournal journal)
    {
      foreach (var signal in await journal.ReadSavedSignalsAsync(chat, chat.WorkerSequence, cancellationToken))
      {
        if (signal.Sequence <= chat.WorkerSequence) continue;
        if (signal.Sequence != chat.WorkerSequence + 1) throw new IOException("This chat’s saved events have a gap. Its messages are kept.");
        chat = ApplySignal(chat, signal); Save(chat);
      }
    }
    var observation = await processes.ObserveAsync(Session(chat), cancellationToken);
    if (observation.Presence == ProcessPresence.Live)
    {
      Follow(chat);
      foreach (var pending in chat.Messages.Where(m => Unconfirmed(chat, m)))
      {
        var receipt = await processes.SendAsync(chat, pending, cancellationToken);
        if (receipt.ClientId != pending.ClientId) throw new IOException("The chat returned another message’s receipt.");
        Save(Replace(Get(chat.Definition.Id), pending with { State = receipt.State }));
      }
      if (!chat.Busy && !chat.Paused && !chat.Messages.Any(m => Unconfirmed(chat, m)) && chat.Messages.FirstOrDefault(m => m.State == ChatMessageState.Queued) is { } queued) await DispatchAsync(Get(chat.Definition.Id), queued, cancellationToken);
      if (chat.ActiveClientId is { } client && chat.WaitingSince is { } since) _ = NoAnswerAsync(chat.Definition.Id, client, since);
    }
    else if (observation.Presence == ProcessPresence.Dead)
    {
      var messages = chat.Messages.Select(m => m.State == ChatMessageState.Dispatching ? m with { State = ChatMessageState.Uncertain } : chat.Busy && m.ClientId == chat.ActiveClientId && m.State == ChatMessageState.Sent ? m with { State = ChatMessageState.Failed } : m).ToArray();
      Save(chat with { Busy = false, ActiveClientId = null, WaitingSince = null, Messages = messages,
        CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0, Paused = chat.Paused || chat.Busy, Stopping = false,
        Problem = messages.Any(m => Unconfirmed(chat, m)) ? "A message may have reached the coding AI. Check its history before sending again." : chat.Busy ? "The coding AI stopped. Your messages are kept. Retry to continue." : chat.Problem });
    }
    else
    {
      Save(chat with { Problem = "This chat is waiting to reconnect. Your messages are kept." });
      if (sending) throw new IOException("This chat is waiting to reconnect. Your messages are kept.");
    }
  }
  // Update handover: stop each chat's coding-AI process but keep the chat, its
  // messages and its conversation id. The next version resumes that
  // conversation on the next message. An answer in progress is marked so it is
  // never sent twice.
  public async ValueTask<int> PrepareUpdateAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var open = chats.Values.Where(c => !c.Ended).ToArray();
      foreach (var chat in open)
        if ((await processes.ObserveAsync(Session(chat), cancellationToken)).Presence == ProcessPresence.Unknown)
          throw new IOException("A chat could not be reached safely, so the update was not applied. Nothing was stopped.");
      foreach (var original in open)
      {
        await RetireWorkerAsync(original, cancellationToken);
        var chat = Get(original.Definition.Id);
        var messages = chat.Messages.Select(m => m.State == ChatMessageState.Dispatching ? m with { State = ChatMessageState.Uncertain } : chat.Busy && m.ClientId == chat.ActiveClientId && m.State == ChatMessageState.Sent ? m with { State = ChatMessageState.Failed } : m).ToArray();
        Save(chat with { Busy = false, ActiveClientId = null, WaitingSince = null, Messages = messages, Stopping = false,
          CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0, Paused = chat.Paused || chat.Busy,
          Problem = chat.Busy ? "Terminal Deck was updated while the coding AI was answering. Your messages are kept. Retry to continue." : chat.Problem });
      }
      return open.Length;
    }
    finally { gate.Release(); }
  }
  private void Follow(ChatRecord chat)
  {
    if (followers.TryGetValue(chat.CreationKey, out var current) && !current.IsCompleted) return;
    followers[chat.CreationKey] = ConsumeAsync(chat);
  }
  private async Task ConsumeAsync(ChatRecord original)
  {
    try
    {
      await foreach (var signal in processes.WatchAsync(original, original.WorkerSequence, lifetime.Token))
      {
        await gate.WaitAsync(lifetime.Token);
        try
        {
          var chat = Get(original.Definition.Id);
          if (chat.Ended || chat.CreationKey != original.CreationKey) return;
          if (signal.Sequence <= chat.WorkerSequence) continue;
          if (signal.Sequence != chat.WorkerSequence + 1) { Save(chat with { Problem = "This chat needs to reconnect before more messages can be sent." }); return; }
          var shouldDrain = chat.Busy && !chat.Paused && (signal.ClientId is null || signal.ClientId == chat.ActiveClientId) && signal.Kind == "complete";
          chat = ApplySignal(chat, signal);
          Save(chat);
          if (shouldDrain && chat.Messages.FirstOrDefault(m => m.State == ChatMessageState.Queued) is { } pending)
            await DispatchAsync(chat, pending, lifetime.Token);
        }
        finally { gate.Release(); }
      }
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    catch (Exception ex) when (ex is IOException or InvalidOperationException)
    {
      await gate.WaitAsync();
      try { var chat = Get(original.Definition.Id); if (chat.CreationKey == original.CreationKey) Save(chat with { Problem = "This chat needs to reconnect. Your messages are kept." }); }
      finally { gate.Release(); }
    }
  }
  private ChatRecord ApplySignal(ChatRecord chat, ChatSignal signal)
  {
    var matchesActive = signal.ClientId is null || signal.ClientId == chat.ActiveClientId;
    var wasStopping = chat.Stopping;
    chat = chat with { WorkerSequence = signal.Sequence };
    if (signal.Kind == "conversation") chat = chat with { ConversationId = signal.Text, Definition = chat.Definition with { ForkSession = false } };
    if (signal.Kind == "accepted" && signal.ClientId is not null)
    {
      var message = chat.Messages.FirstOrDefault(m => m.ClientId == signal.ClientId);
      if (message is not null && message.State is ChatMessageState.Queued or ChatMessageState.Dispatching or ChatMessageState.Uncertain) chat = Replace(chat, message with { State = ChatMessageState.Sent }) with { Problem = chat.Problem?.Contains("may have reached", StringComparison.Ordinal) == true ? null : chat.Problem };
    }
    if (signal.Kind is "textDelta" or "message" or "toolCall" or "approval") chat = chat with { WaitingSince = null, Problem = null };
    if (signal.Kind != "approvalResolved" || !chat.Events.Any(e => e.Kind == "approvalResolved" && e.Id == signal.Id)) chat = Add(chat, signal.Kind, signal.Id, signal.Text, signal.ClientId, signal.Data);
    if (matchesActive && signal.Kind == "connectionLost")
    {
      var pending = chat.Messages.FirstOrDefault(m => m.ClientId == chat.ActiveClientId);
      if (pending is not null) chat = Replace(chat, pending with { State = ChatMessageState.Uncertain });
      return chat with { Busy = false, ActiveClientId = null, WaitingSince = null, Stopping = false, Paused = true, Problem = signal.Text };
    }
    if (matchesActive && signal.Kind is "complete" or "error" or "exit")
    {
      var active = chat.Messages.FirstOrDefault(m => m.ClientId == chat.ActiveClientId);
      if (signal.Kind == "complete" && active is not null && Unconfirmed(chat, active))
        chat = Replace(chat, active with { State = ChatMessageState.Sent });
      if (signal.Kind == "error" && active is not null) chat = Replace(chat, active with { State = ChatMessageState.Failed });
      chat = chat with { Busy = false, ActiveClientId = null, WaitingSince = null, Stopping = false, Problem = signal.Kind == "error" ? signal.Text : chat.Problem };
    }
    if (matchesActive && wasStopping && signal.Kind == "complete") chat = Add(chat, "stopped", signal.ClientId + ":stop", chat.Paused ? "Stopped. Queued messages are kept." : "Stopped.");
    return chat;
  }
  private async Task NoAnswerAsync(string id, string clientId, DateTimeOffset since)
  {
    try
    {
      var remaining = TimeSpan.FromMinutes(1) - (clock.GetUtcNow() - since);
      if (remaining > TimeSpan.Zero) await Task.Delay(remaining, clock, lifetime.Token);
      await gate.WaitAsync(lifetime.Token);
      try
      {
        var chat = Get(id);
        if (chat.ActiveClientId == clientId && chat.WaitingSince == since)
          Save(chat with { Problem = "No answer yet. Stop and retry when you’re ready." });
      }
      finally { gate.Release(); }
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
  }
  public async IAsyncEnumerable<ChatRecord> WatchAsync(string id, [EnumeratorCancellation] CancellationToken cancellationToken = default)
  {
    var key = Guid.NewGuid(); var channel = Channel.CreateBounded<ChatRecord>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
    await gate.WaitAsync(cancellationToken);
    try { watchers[key] = (id, channel); channel.Writer.TryWrite(Get(id)); }
    finally { gate.Release(); }
    try { await foreach (var chat in channel.Reader.ReadAllAsync(cancellationToken)) yield return chat; }
    finally { watchers.TryRemove(key, out _); }
  }
  private void Save(ChatRecord chat)
  {
    history.Save(chat); chats[chat.Definition.Id] = chat;
    foreach (var watcher in watchers.Values.Where(w => w.Id == chat.Definition.Id)) watcher.Channel.Writer.TryWrite(chat);
  }
  private ChatRecord Add(ChatRecord chat, string kind, string id, string text = "", string? client = null, JsonElement? data = null) =>
    chat with { Events = [.. chat.Events, new(chat.Events.LastOrDefault()?.Sequence + 1 ?? 1, kind, id, text, client, data, clock.GetUtcNow())] };
  private static ChatRecord Replace(ChatRecord chat, ChatMessage message) => chat with { Messages = chat.Messages.Select(m => m.ClientId == message.ClientId ? message : m).ToArray() };
  private static ChatMessage Queued(ChatRecord chat, string clientId) => chat.Messages.FirstOrDefault(m => m.ClientId == clientId && m.State == ChatMessageState.Queued) ?? throw new InvalidOperationException("That message is no longer queued.");
  public static bool Unconfirmed(ChatRecord chat, ChatMessage message) => message.State == ChatMessageState.Dispatching ||
    message.State == ChatMessageState.Uncertain && !chat.Events.Any(e => e.Kind == "uncertaintyAcknowledged" && e.ClientId == message.ClientId);
  private static void RequireActive(ChatRecord chat) { if (chat.Ended) throw new InvalidOperationException("This chat has ended. Start a new chat to continue."); }
  private static void RequireIdle(ChatRecord chat) { RequireActive(chat); if (chat.Busy || chat.Stopping || chat.Messages.Any(m => m.State == ChatMessageState.Queued || Unconfirmed(chat, m)) || chat.Events.Any(e => e.Kind == "approval" && !chat.Events.Any(answer => answer.Kind == "approvalResolved" && answer.Id == e.Id))) throw new InvalidOperationException("Finish this answer, its approval requests and its queued messages first."); }
  private async ValueTask RetireWorkerAsync(ChatRecord chat, CancellationToken ct)
  {
    var observation = await processes.ObserveAsync(Session(chat), ct);
    if (observation.Presence == ProcessPresence.Unknown) throw new IOException("Reconnect before changing this chat.");
    if (observation.Presence == ProcessPresence.Live) await processes.QuitAsync(chat.CreationKey, ct);
  }
  public static SessionRecord Session(ChatRecord chat) => new(new(chat.Definition.Id, chat.Definition.Provider, chat.Definition.Cwd, chat.Definition.Title,
    chat.Definition.AccountId, chat.Definition.AccountHome, chat.ConversationId), chat.CreationKey, SessionState.Running, chat.CreationKey, HasStarted: chat.WorkerSequence > 0);
  private bool HaveOriginalFiles(ChatRecord chat, ChatMessage message)
  {
    try { foreach (var image in message.Media) _ = history.ReadMedia(chat.Definition.Id, image); return true; }
    catch (Exception ex) when (ex is IOException or ArgumentException) { return false; }
  }
  private static void ValidateMessage(string id, string text, ChatMedia[] media)
  {
    ChatText.ValidatePrompt(text);
    if (!Guid.TryParse(id, out _) || string.IsNullOrWhiteSpace(text) && media.Length == 0 || media.Length > 8 || text.Contains('\0'))
      throw new ArgumentException("Write a message or add up to eight images.");
  }
  public async ValueTask DisposeAsync()
  {
    lifetime.Cancel();
    Task[] tasks; await gate.WaitAsync(); try { tasks = followers.Values.ToArray(); } finally { gate.Release(); }
    await Task.WhenAll(tasks);
    foreach (var watcher in watchers.Values) watcher.Channel.Writer.TryComplete();
    lifetime.Dispose();
  }
}
public sealed class ChatFilesNeededException() : InvalidOperationException(ChatErrors.OriginalFilesNeeded);
public static class ChatErrors
{
  public const string OriginalFilesNeeded = "Original files are needed. Add the original files again before sending this prompt. Nothing has been resent.";
  public static string NotSignedIn(string provider) => $"Not signed in to {provider switch { "claude" => "Claude", "codex" => "Codex", _ => "Gemini" }}. Sign in to continue.";
  public const string LimitPrefix = "This account has reached its ";
  public static bool IsUsageLimit(string? text) => text?.StartsWith(LimitPrefix, StringComparison.Ordinal) == true;
  // Claude: "You've hit your weekly limit · resets 2pm (Asia/Dubai)" (also session/Opus limits);
  // Codex: "You've hit your usage limit … try again at 3:05 PM"; others report a 429/quota.
  public static string? UsageLimit(string message)
  {
    var hit = System.Text.RegularExpressions.Regex.Match(message, @"hit your (?<kind>[\w\s-]{0,30}?)\s*limit(?:.*?\b(?:resets|try again at|try again)\s+(?<reset>[^.\n]{1,60}))?", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Singleline);
    string kind, reset;
    if (hit.Success) { kind = hit.Groups["kind"].Value.Trim().ToLowerInvariant(); reset = hit.Groups["reset"].Value.Trim(); }
    else if (new[] { "usage limit", "rate limit", "rate_limit", "quota exceeded", "resource_exhausted" }.Any(s => message.Contains(s, StringComparison.OrdinalIgnoreCase))) { kind = "usage"; reset = ""; }
    else return null;
    var name = kind is "" or "usage" ? "usage limit" : kind == "session" ? "session limit (5 hours)" : kind + " limit";
    return LimitPrefix + name + (reset.Length > 0 ? " — resets " + reset : "") + ". Switch account?";
  }
  public static string FromProvider(string provider, string message) =>
    UsageLimit(message) ?? (new[] { "not logged in", "not signed in", "authentication", "unauthorized", "login", "sign in", "api key", "credentials" }.Any(s => message.Contains(s, StringComparison.OrdinalIgnoreCase))
      ? NotSignedIn(provider) : "The coding AI could not answer. Retry when you’re ready.");
}
