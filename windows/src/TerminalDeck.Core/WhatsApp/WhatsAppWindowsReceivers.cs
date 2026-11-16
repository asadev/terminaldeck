using System.Text;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.WhatsApp;

/// The receivers door on Windows (the Mac's NativeWhatsAppReceivers), over the same paths the phone link uses:
/// - a chat session: IChatSessions.SendAsync (pictures and PDF through AddImageAsync), its rows for the final answer and
///   the waiting approvals (ChatProjection), AnswerAsync for "1" / "2";
/// - Hoot: IHoot.SayAsync / SayWithAttachmentsAsync as the person (HootSource "person", as the phone), his turns for the
///   answer, his approval lines, IHoot.AnswerAsync. Windows has ONE Hoot conversation (no lasting conversation per
///   WhatsApp agent as on the Mac): the messages go into Hoot's own conversation;
/// - an agent: a kept-open chat of that saved agent, started on first use by `startAgentChat` (kept while the app runs);
/// - a terminal: the keeper's write (text with Return) and the session's replay as plain text (escape codes removed).
public sealed partial class WhatsAppWindowsReceivers(
  IChatSessions chats,
  Func<IHoot?> hoot,
  Func<IReadOnlyList<SessionRecord>> terminals,
  Func<string, byte[], Task> writeTerminal,
  Func<string, string, Task<string?>> startAgentChat,
  Func<Task>? refreshTerminals = null) : IWhatsAppReceiverPort
{
  public const string HootTarget = "hoot";
  private readonly Lock gate = new();
  /// WhatsApp agent id -> the agent's kept-open chat id.
  private readonly Dictionary<string, string> agentChats = new(StringComparer.Ordinal);

  private ChatRecord? Chat(string id) { try { return chats.List().FirstOrDefault(c => c.Definition.Id == id); } catch (Exception) { return null; } }
  private SessionRecord? Terminal(string id) => terminals().FirstOrDefault(s => s.Definition.Id == id);

  public async Task<WhatsAppTarget?> TargetAsync(WhatsAppReceiver receiver, string conversationName, string agentId)
  {
    switch (receiver.Kind)
    {
      case WhatsAppReceiverKind.Hoot: return hoot() is null ? null : new WhatsAppTarget(HootTarget, false);
      case WhatsAppReceiverKind.Agent:
      {
        string? known; lock (gate) agentChats.TryGetValue(agentId, out known);
        if (known is not null && Chat(known) is { Ended: false }) return new WhatsAppTarget(known, false);
        var made = await startAgentChat(receiver.Id, conversationName);
        if (made is null) return null;
        lock (gate) agentChats[agentId] = made;
        return new WhatsAppTarget(made, false);
      }
      case WhatsAppReceiverKind.Session:
        if (Chat(receiver.Id) is { } chat) return chat.Ended ? null : new WhatsAppTarget(receiver.Id, false);
        if (Terminal(receiver.Id) is { } term) return term.State == SessionState.Exited ? null : new WhatsAppTarget(receiver.Id, true);
        return null;
      default: return null;
    }
  }

  public async Task SayAsync(WhatsAppTarget target, string text, IReadOnlyList<WhatsAppAttachment> attachments)
  {
    var files = attachments.Select(a => ChatAttachmentData.Read(a.FileName ?? Default(a.MimeType), a.Data)).ToArray();
    if (target.SessionId == HootTarget)
    {
      var h = hoot() ?? throw new InvalidOperationException("Hoot is not ready on this computer.");
      if (files.Length == 0) await h.SayAsync(Guid.NewGuid().ToString(), text, new HootSource("person"));
      else await h.SayWithAttachmentsAsync(Guid.NewGuid().ToString(), text, files, new HootSource("person"));
      return;
    }
    var chat = Chat(target.SessionId) ?? throw new InvalidOperationException("That chat is not open.");
    var media = new List<ChatMedia>();
    foreach (var file in files)
    {
      file.Validate(chat.Definition.Provider);
      media.Add(await chats.AddImageAsync(target.SessionId, file.Name, file.MimeType, file.Data, file.Width, file.Height));
    }
    await chats.SendAsync(target.SessionId, Guid.NewGuid().ToString(), text, media.Count == 0 ? null : media.ToArray());
  }
  private static string Default(string mime) => mime switch { "application/pdf" => "document.pdf", "image/png" => "picture.png", _ => "picture.jpg" };

  public Task<WhatsAppTurn?> TurnAsync(WhatsAppTarget target)
  {
    if (target.SessionId == HootTarget) return Task.FromResult(hoot() is { } h ? HootTurnOf(h.Read()) : null);
    return Task.FromResult(Chat(target.SessionId) is { } chat ? ChatTurnOf(chat) : null);
  }

  /// A chat's turn now: approvals waiting, working, failed, or its last answer (the assistant rows after the last message
  /// he sent, joined), named by that message's id.
  public static WhatsAppTurn ChatTurnOf(ChatRecord chat)
  {
    var rows = ChatProjection.Rows(chat);
    var waiting = rows.Where(r => r.Kind == "approval" && r.Waiting)
      .Select(r => new WhatsAppApproval(r.Id, "It asks to use " + r.Text + ".", r.Details)).ToArray();
    var last = chat.Messages.LastOrDefault(m => m.State != ChatMessageState.Removed);
    if (waiting.Length > 0) return WhatsAppTurn.Asking(last?.ClientId, waiting);
    if (chat.Busy) return WhatsAppTurn.Working(chat.ActiveClientId ?? last?.ClientId);
    if (last is null) return WhatsAppTurn.Idle(null);
    if (last.State == ChatMessageState.Failed) return WhatsAppTurn.Failed(last.ClientId, chat.Problem ?? "It stopped.");
    if (last.State is ChatMessageState.Queued or ChatMessageState.Dispatching) return WhatsAppTurn.Working(last.ClientId);
    var answer = string.Join("\n\n", rows.Where(r => r.Kind == "assistant" && r.ClientId == last.ClientId).Select(r => r.Text.Trim()).Where(t => t.Length > 0));
    return answer.Length == 0 ? WhatsAppTurn.Idle(last.ClientId) : WhatsAppTurn.Done(last.ClientId, answer);
  }

  /// Hoot's turn now: his waiting approval lines, working, or his last turn's answer.
  public static WhatsAppTurn HootTurnOf(HootState state)
  {
    var waiting = state.Lines.Where(l => l.Kind == "approval" && l.Waiting && l.RequestId is not null)
      .Select(l => new WhatsAppApproval(l.RequestId!, "It asks to use " + l.Text + ".", l.Details)).ToArray();
    var last = state.Turns.LastOrDefault();
    if (waiting.Length > 0) return WhatsAppTurn.Asking(last?.Id, waiting);
    if (state.Active is { } active) return WhatsAppTurn.Working(active.Id);
    if (last is null) return WhatsAppTurn.Idle(null);
    return last.State switch
    {
      HootTurnState.Finished => WhatsAppTurn.Done(last.Id, last.Answer),
      HootTurnState.Failed => WhatsAppTurn.Failed(last.Id, last.Problem ?? "It stopped."),
      HootTurnState.Queued or HootTurnState.Dispatching or HootTurnState.Running => WhatsAppTurn.Working(last.Id),
      _ => WhatsAppTurn.Idle(last.Id),
    };
  }

  public async Task<bool> ApproveAsync(WhatsAppTarget target, string approvalId, bool allow)
  {
    if (await TurnAsync(target) is not { Kind: WhatsAppTurnKind.NeedsApproval } turn || turn.Waiting.All(a => a.Id != approvalId)) return false;
    if (target.SessionId == HootTarget) { if (hoot() is not { } h) return false; await h.AnswerAsync(approvalId, allow); return true; }
    await chats.AnswerAsync(target.SessionId, approvalId, allow);
    return true;
  }

  public Task TypeAsync(WhatsAppTarget target, string text) => writeTerminal(target.SessionId, Encoding.UTF8.GetBytes(text));

  public async Task<string?> ScreenAsync(WhatsAppTarget target)
  {
    if (refreshTerminals is not null) { try { await refreshTerminals(); } catch (Exception) { } }
    return Terminal(target.SessionId) is { } s ? PlainText(s.Replay) : null;
  }

  /// The replay as text: escape sequences removed, "\r\n" as "\n", a lone carriage return dropped.
  public static string PlainText(string replay)
  {
    var text = Escapes().Replace(replay, "");
    return text.Replace("\r\n", "\n").Replace("\r", "");
  }
  [GeneratedRegex(@"\x1B\][^\x07\x1B]*(\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[P^_][^\x1B]*\x1B\\|\x1B[@-Z\\-_]|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")]
  private static partial Regex Escapes();

  public Task<bool> IsOpenAsync(WhatsAppTarget target)
  {
    if (target.SessionId == HootTarget) return Task.FromResult(hoot() is not null);
    if (target.IsTerminal) return Task.FromResult(Terminal(target.SessionId) is { } s && s.State != SessionState.Exited);
    return Task.FromResult(Chat(target.SessionId) is { Ended: false });
  }

  public Task<bool> IsToolSessionAsync(WhatsAppTarget target, string sessionId) =>
    Task.FromResult(target.SessionId == sessionId || target.SessionId == HootTarget && hoot()?.Read().ChatId == sessionId);
}
