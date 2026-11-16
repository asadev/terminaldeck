using System.Text;

namespace TerminalDeck.Core.WhatsApp;

/// One WhatsApp agent read by THIS computer (DESIGN-WHATSAPP.md sections 4 and 5), a port of the Mac's
/// BackendWhatsAppLink.swift: its poll loop, his messages into the receiver, and the receiver's answers and approvals back
/// to him. Exactly one link per agent per app (the engine holds them by agent id), and only on the computer that is the
/// agent's reader. Sends to him go strictly one after another. Take and Look run one at a time (the Mac's actor).
public sealed class WhatsAppLink
{
  /// Timings of design sections 1 and 4 (tests shorten the waits through the clock, never these rules).
  public static class Timing
  {
    public const int PollTimeout = 25;
    /// 15 polls a minute.
    public const double PollGap = 4.0;
    public const double TypingEvery = 20.0;
    public const double WatchEvery = 2.0;
    public const double LateAfter = 24 * 3600;
    public const double TerminalQuiet = 2.0;
    public const double TerminalLongest = 120.0;
    public const int TerminalLines = 40;
    public const long ImageLimit = 5L * 1024 * 1024;
    public const long OtherLimit = 16L * 1024 * 1024;
    /// After a 409 while the record still names this computer: poll again after this long (review fault 2).
    public const double AfterReplaced = 30.0;
  }
  public static class Words
  {
    public const string Late = "This reached me late; send it again if you still need it.";
    public const string NotRead = "I read text, pictures and documents here.";
    public const string Ended = "That session has ended. Choose where I should answer in Terminal Deck.";
    public const string Nowhere = "This WhatsApp agent is not received anywhere right now. Choose where I should answer in Terminal Deck.";
    public const string Reply = "Reply 1 to allow, 2 to deny.";
    public const string FileTooLarge = "That file is larger than WhatsApp lets me fetch.";
    public const string DocumentKind = "I read pictures, PDF and text documents here.";
    public const string NoOutput = "(no output)";
    public const string TerminalTextOnly = "A terminal takes text only here.";
  }
  public enum StopReason { NotReader, KeyRefused }

  public string AgentId { get; }
  private readonly string key;
  private readonly IWhatsAppTransport transport;
  private readonly IWhatsAppReceiverPort receivers;
  private readonly IWhatsAppClock clock;
  private readonly Func<Task<WhatsAppAgentRecord?>> read;
  private readonly Func<Func<WhatsAppAgentRecord, WhatsAppAgentRecord>, Task> update;
  private readonly Func<StopReason, Task> stopped;
  private readonly Func<Task<bool>> stillReader;
  /// The fingerprint of the key this link reads with (never the key).
  public string KeyId { get; }

  private readonly SemaphoreSlim turnGate = new(1, 1);
  private readonly Lock outGate = new();
  private Task outbox = Task.CompletedTask;
  private CancellationTokenSource? running;
  private WhatsAppTarget? target;
  private string? deliveredTurn;
  private bool seededTurn;
  private readonly HashSet<string> askedApprovals = new(StringComparer.Ordinal);
  /// The ONE approval asked on WhatsApp and not yet answered (review fault 3).
  private (WhatsAppTarget Target, string Id, DateTimeOffset AskedAt)? openApproval;
  private string? typingFor;
  private DateTimeOffset? typedAt;
  private DateTimeOffset? lastPoll;

  public WhatsAppLink(string agentId, string key, IWhatsAppTransport transport, IWhatsAppReceiverPort receivers, IWhatsAppClock clock,
    Func<Task<WhatsAppAgentRecord?>> read, Func<Func<WhatsAppAgentRecord, WhatsAppAgentRecord>, Task> update, Func<StopReason, Task> stopped,
    Func<Task<bool>>? stillReader = null)
  {
    AgentId = agentId; this.key = key; this.transport = transport; this.receivers = receivers; this.clock = clock;
    this.read = read; this.update = update; this.stopped = stopped; this.stillReader = stillReader ?? (() => Task.FromResult(true));
    KeyId = WhatsAppAgentIds.Fingerprint(key);
  }
  public override string ToString() => $"WhatsAppLink {{ {AgentId} }}";

  public void Start()
  {
    lock (outGate)
    {
      if (running is not null) return;
      running = new CancellationTokenSource();
    }
    var token = running.Token;
    _ = Task.Run(() => RunAsync(token));
    _ = Task.Run(() => WatchAsync(token));
  }
  public void Stop()
  {
    CancellationTokenSource? was;
    lock (outGate) { was = running; running = null; }
    try { was?.Cancel(); } catch (ObjectDisposedException) { }
  }
  public bool IsRunning { get { lock (outGate) return running is not null; } }
  /// The session his messages go to now (null until the first one, or after it ended).
  public WhatsAppTarget? CurrentTarget => target;

  private async Task SleepAsync(double seconds, CancellationToken token = default)
  {
    try { await clock.DelayAsync(TimeSpan.FromSeconds(Math.Max(0, seconds)), token).ConfigureAwait(false); }
    catch (OperationCanceledException) { }
  }
  private double Since(DateTimeOffset at) => (clock.Now - at).TotalSeconds;
  private Task UpdateAsync(Func<WhatsAppAgentRecord, WhatsAppAgentRecord> change) => update(change);
  private async Task StopForAsync(StopReason why, CancellationToken token)
  {
    if (token.IsCancellationRequested) return;
    Stop();
    await stopped(why).ConfigureAwait(false);
  }

  // ---- Reading (one reader per agent) ----

  private async Task<WhatsAppPoll> PollSpacedAsync(long? offset, int timeout, CancellationToken token)
  {
    if (lastPoll is { } last)
    {
      var wait = Timing.PollGap - Since(last);
      if (wait > 0) await SleepAsync(wait, token);
    }
    lastPoll = clock.Now;
    try { return await transport.PollAsync(key, offset, timeout, token).ConfigureAwait(false); }
    catch (OperationCanceledException) { return WhatsAppPoll.NothingNew; }
  }

  private async Task RunAsync(CancellationToken token)
  {
    while (!token.IsCancellationRequested)
    {
      if (await read().ConfigureAwait(false) is not { Removed: false, Refused: false } record) return;
      // First connect of this key: read the backlog only to learn the creator and the head; answer nothing of it.
      if (record.Offset is null)
      {
        if (await LearnHeadAsync(token) is not { } head) return;
        if (!await stillReader()) { await StopForAsync(StopReason.NotReader, token); return; }
        await UpdateAsync(r => r with { Offset = head.Offset, Creator = head.Creator ?? r.Creator });
        continue;
      }
      var result = await PollSpacedAsync(record.Offset, Timing.PollTimeout, token);
      if (token.IsCancellationRequested) return;
      switch (result)
      {
        case WhatsAppPoll.Nothing: continue;
        case WhatsAppPoll.Replaced:
          // Fault 2: another reader polled. While the record still names this computer, try again in ~30 s;
          // otherwise stop and let the settings decide.
          if (!await stillReader()) { await StopForAsync(StopReason.NotReader, token); return; }
          await SleepAsync(Timing.AfterReplaced, token);
          break;
        case WhatsAppPoll.KeyRefused:
          await UpdateAsync(r => r with { Refused = true });
          await StopForAsync(StopReason.KeyRefused, token); return;
        case WhatsAppPoll.BackOff b: await SleepAsync(Math.Max(1, b.Seconds), token); break;
        case WhatsAppPoll.Messages m:
          // Fault 2: the batch is handled only while the record still names this computer.
          if (!await stillReader()) { await StopForAsync(StopReason.NotReader, token); return; }
          foreach (var message in m.Items) { if (token.IsCancellationRequested) break; await TakeAsync(message); }
          var stamps = m.Items.Where(x => x.Kind != WhatsAppInboundKind.Reaction).Select(x => (double)x.Timestamp.ToUnixTimeMilliseconds()).ToArray();
          double? newest = stamps.Length > 0 ? stamps.Max() : null;
          var creator = m.Items.Count > 0 ? m.Items[^1].From : null;
          var next = m.Next;
          await UpdateAsync(r => r with
          {
            Offset = next,
            Creator = r.Creator ?? creator,
            LastMessageAt = newest is double n ? Math.Max(r.LastMessageAt ?? 0, n) : r.LastMessageAt,
          });
          break;
      }
    }
  }

  /// The backlog read with timeout=0 until nothing is left: the creator (from any message) and the head.
  private async Task<(long Offset, string? Creator)?> LearnHeadAsync(CancellationToken token)
  {
    long offset = 0; string? creator = null;
    while (!token.IsCancellationRequested)
    {
      switch (await PollSpacedAsync(offset, 0, token))
      {
        case WhatsAppPoll.Nothing: return (offset, creator);
        case WhatsAppPoll.Messages m:
          if (m.Items.Count > 0) creator = m.Items[^1].From;
          if (m.Next == offset) return (offset, creator);
          offset = m.Next; break;
        case WhatsAppPoll.Replaced:
          if (!await stillReader()) { await StopForAsync(StopReason.NotReader, token); return null; }
          await SleepAsync(Timing.AfterReplaced, token); break;
        case WhatsAppPoll.KeyRefused:
          await UpdateAsync(r => r with { Refused = true });
          await StopForAsync(StopReason.KeyRefused, token); return null;
        case WhatsAppPoll.BackOff b: await SleepAsync(Math.Max(1, b.Seconds), token); break;
      }
    }
    return null;
  }

  // ---- One message from him ----

  public static bool? ApprovalAnswer(string? text) => text?.Trim().ToLowerInvariant() switch
  {
    "1" or "allow" => true,
    "2" or "deny" => false,
    _ => null,
  };

  private Task MarkAsync(string id, bool typing) => transport.MarkReadAsync(key, id, typing);

  public async Task TakeAsync(WhatsAppInbound message)
  {
    await turnGate.WaitAsync().ConfigureAwait(false);
    try { await TakeLockedAsync(message); }
    finally { turnGate.Release(); }
  }

  private async Task TakeLockedAsync(WhatsAppInbound message)
  {
    if (await read() is not { } record) return;
    // Only the creator can write to an agent; anything else is not his and is left alone.
    if (record.Creator is { } creator && creator != message.From) return;
    if (record.Creator is null) { var from = message.From; await UpdateAsync(r => r with { Creator = from }); }
    if (message.Kind == WhatsAppInboundKind.Reaction) return;
    // A message he writes from WhatsApp turns the switch on by itself: it is answered there.
    if (!record.IsSending) await UpdateAsync(r => r with { Sending = true });
    var to = message.From;
    if (Since(message.Timestamp) > Timing.LateAfter) { await MarkAsync(message.Id, false); Send(Words.Late, to); return; }
    if (message.Kind is not (WhatsAppInboundKind.Text or WhatsAppInboundKind.Image or WhatsAppInboundKind.Document))
    {
      await MarkAsync(message.Id, false); Send(Words.NotRead, to); return;
    }
    if (record.EndedSession)
    {
      await MarkAsync(message.Id, false);
      Send(Words.Ended, to);
      await UpdateAsync(r => r with { EndedSession = false });
      return;
    }
    // "1" / "2" answers the one open question, only when written at or after it was asked (fault 3).
    if (message.Kind == WhatsAppInboundKind.Text && ApprovalAnswer(message.Text) is bool allow && openApproval is { } open
      && message.Timestamp >= DateTimeOffset.FromUnixTimeSeconds(open.AskedAt.ToUnixTimeSeconds()))
    {
      openApproval = null;
      bool done;
      try { done = await receivers.ApproveAsync(open.Target, open.Id, allow); } catch (Exception) { done = false; }
      if (done)
      {
        await MarkAsync(message.Id, true);
        typingFor = message.Id; typedAt = clock.Now;
        return;
      }
    }
    WhatsAppTarget? found;
    try { found = await receivers.TargetAsync(record.Receiver, record.Name, AgentId); } catch (Exception) { found = null; }
    if (found is null)
    {
      await MarkAsync(message.Id, false);
      if (record.Receiver.Kind == WhatsAppReceiverKind.Session)
      {
        await UpdateAsync(r => r with { Receiver = WhatsAppReceiver.Nowhere });
        Send(Words.Ended, to);
      }
      else Send(Words.Nowhere, to);
      return;
    }
    if (target != found) { target = found; seededTurn = false; }
    // Fault 4: a terminal takes text only; a picture or document is never typed into the shell.
    if (found.IsTerminal && message.Kind != WhatsAppInboundKind.Text)
    {
      await MarkAsync(message.Id, false); Send(Words.TerminalTextOnly, to); return;
    }
    await MarkAsync(message.Id, true);
    typingFor = message.Id; typedAt = clock.Now;
    // Pictures and documents arrive as attachments of his message.
    var text = message.Text ?? message.Caption ?? "";
    var attachments = new List<WhatsAppAttachment>();
    if (message.Kind is WhatsAppInboundKind.Image or WhatsAppInboundKind.Document && message.MediaId is { } media)
    {
      var limit = message.Kind == WhatsAppInboundKind.Image ? Timing.ImageLimit : Timing.OtherLimit;
      WhatsAppMedia? fetched;
      try { fetched = await transport.MediaAsync(key, media, limit); } catch (Exception) { fetched = null; }
      if (fetched is null) { typingFor = null; Send(Words.FileTooLarge, to); return; }
      switch (AttachmentKindOf(fetched.MimeType))
      {
        case AttachmentKind.Chat: attachments.Add(new(fetched.Data, fetched.MimeType, message.FileName ?? fetched.FileName)); break;
        case AttachmentKind.Text:
          var name = message.FileName ?? fetched.FileName ?? "document";
          text += (text.Length == 0 ? "" : "\n\n") + name + ":\n" + Encoding.UTF8.GetString(fetched.Data, 0, Math.Min(fetched.Data.Length, 131_072));
          break;
        default: typingFor = null; Send(Words.DocumentKind, to); return;
      }
    }
    if (found.IsTerminal) { await TerminalAsync(found, text, to); return; }
    // The answer to THIS message must be sent even when it is ready before the next look: what was there before is the
    // only thing marked as already given.
    if (!seededTurn)
    {
      seededTurn = true;
      if (await receivers.TurnAsync(found) is { } before && before.Kind is WhatsAppTurnKind.Done or WhatsAppTurnKind.Failed or WhatsAppTurnKind.Idle)
        deliveredTurn = before.TurnId;
    }
    try { await receivers.SayAsync(found, text, attachments); }
    catch (Exception error)
    {
      typingFor = null;
      Send("That did not reach the chat: " + Plain(error), to);
    }
  }

  public enum AttachmentKind { Chat, Text, Refused }
  /// What a chat takes as an attachment (pictures and PDF), what is read as text, and what is not taken.
  public static AttachmentKind AttachmentKindOf(string mime)
  {
    var lower = mime.ToLowerInvariant();
    if (lower is "image/png" or "image/jpeg" or "image/gif" or "image/webp" or "application/pdf") return AttachmentKind.Chat;
    if (lower.StartsWith("text/", StringComparison.Ordinal) || lower is "application/json" or "application/xml") return AttachmentKind.Text;
    return AttachmentKind.Refused;
  }
  public static string Plain(Exception error)
  {
    var words = error is WhatsAppProblem or InvalidOperationException or ArgumentException ? error.Message : "it was refused.";
    return words.Length > 300 ? words[..300] : words;
  }

  /// A terminal session: his text typed in with Return; what it prints once quiet for 2 s comes back (last 40 lines).
  private async Task TerminalAsync(WhatsAppTarget found, string text, string to)
  {
    var before = await receivers.ScreenAsync(found) ?? "";
    try { await receivers.TypeAsync(found, text + "\r"); }
    catch (Exception error) { typingFor = null; Send("That did not reach the terminal: " + Plain(error), to); return; }
    var started = clock.Now;
    var last = before; DateTimeOffset? changedAt = null;
    // Always ends: at the latest after TerminalLongest (the Mac loops until its task is cancelled or one of these).
    while (true)
    {
      await SleepAsync(0.5);
      var now = await receivers.ScreenAsync(found) ?? last;
      if (now != last) { last = now; changedAt = clock.Now; }
      if (changedAt is { } c && Since(c) >= Timing.TerminalQuiet) break;
      if (Since(started) >= Timing.TerminalLongest) break;
      if (changedAt is null && Since(started) >= Timing.TerminalQuiet * 3) break;
    }
    typingFor = null;
    var output = NewLines(before, last);
    Send(output.Length == 0 ? Words.NoOutput : "```\n" + output + "\n```", to, format: false);
  }

  /// The lines the terminal printed after `before` (the screen's last lines when it scrolled), at most 40.
  public static string NewLines(string before, string after)
  {
    var fresh = after.StartsWith(before, StringComparison.Ordinal) ? after[before.Length..] : after;
    var lines = fresh.Split('\n').ToList();
    while (lines.Count > 0 && lines[^1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
    while (lines.Count > 0 && lines[0].Trim().Length == 0) lines.RemoveAt(0);
    return string.Join("\n", lines.Skip(Math.Max(0, lines.Count - Timing.TerminalLines)));
  }

  // ---- The receiver's answers and approvals back to him (every final answer, wherever it was asked) ----

  private async Task WatchAsync(CancellationToken token)
  {
    while (!token.IsCancellationRequested)
    {
      await SleepAsync(Timing.WatchEvery, token);
      if (token.IsCancellationRequested) return;
      try { await LookAsync(); } catch (Exception) { }
    }
  }

  /// One look at the receiver: a new final answer, a new approval, the typing indicator kept alive, an ended session.
  public async Task LookAsync()
  {
    await turnGate.WaitAsync().ConfigureAwait(false);
    try { await LookLockedAsync(); }
    finally { turnGate.Release(); }
  }

  private async Task LookLockedAsync()
  {
    if (await read() is not { Removed: false, Creator: { } to } record) return;
    if (target is null && record.Receiver.Kind != WhatsAppReceiverKind.Nowhere)
    {
      try { target = await receivers.TargetAsync(record.Receiver, record.Name, AgentId); } catch (Exception) { target = null; }
      seededTurn = false;
    }
    if (target is not { IsTerminal: false } here) return;
    if (!await receivers.IsOpenAsync(here))
    {
      target = null;
      if (record.Receiver.Kind == WhatsAppReceiverKind.Session)
        await UpdateAsync(r => r with { Receiver = WhatsAppReceiver.Nowhere, EndedSession = true });
      return;
    }
    if (await receivers.TurnAsync(here) is not { } turn) return;
    // The switch off: nothing goes to WhatsApp; what ends meanwhile counts as given, so turning it on sends no backlog.
    if (!record.IsSending)
    {
      switch (turn.Kind)
      {
        case WhatsAppTurnKind.Done or WhatsAppTurnKind.Failed: deliveredTurn = turn.TurnId; seededTurn = true; break;
        case WhatsAppTurnKind.NeedsApproval: foreach (var a in turn.Waiting) askedApprovals.Add(a.Id); break;
      }
      typingFor = null;
      return;
    }
    // What was already there when this link began is not sent again.
    if (!seededTurn)
    {
      seededTurn = true;
      if (turn.Kind is WhatsAppTurnKind.Done or WhatsAppTurnKind.Failed or WhatsAppTurnKind.Idle) { deliveredTurn = turn.TurnId; return; }
    }
    switch (turn.Kind)
    {
      case WhatsAppTurnKind.Working:
        if (typingFor is { } wamid && Since(typedAt ?? DateTimeOffset.MinValue) >= Timing.TypingEvery)
        {
          typedAt = clock.Now;
          await MarkAsync(wamid, true);
        }
        break;
      case WhatsAppTurnKind.NeedsApproval:
        // Fault 3: one question at a time. The open one stays until answered or gone; then the next is asked.
        if (openApproval is { } open && turn.Waiting.Any(a => a.Id == open.Id)) break;
        openApproval = null;
        if (turn.Waiting.FirstOrDefault(a => !askedApprovals.Contains(a.Id)) is { } next)
        {
          askedApprovals.Add(next.Id);
          openApproval = (here, next.Id, clock.Now);
          Send(ApprovalText(next), to, format: false);
        }
        break;
      case WhatsAppTurnKind.Done:
        if (turn.TurnId == deliveredTurn) return;
        deliveredTurn = turn.TurnId; typingFor = null; openApproval = null;
        if ((turn.Answer ?? "").Trim() is { Length: > 0 } clean) Send(clean, to);
        break;
      case WhatsAppTurnKind.Failed:
        if (turn.TurnId == deliveredTurn) return;
        deliveredTurn = turn.TurnId; typingFor = null; openApproval = null;
        Send(turn.Answer ?? "It stopped.", to);
        break;
    }
  }

  public static string ApprovalText(WhatsAppApproval approval)
  {
    var lines = new List<string> { approval.Summary.Trim() };
    var detail = approval.Detail.Trim();
    if (detail.Length > 0) lines.Add("```\n" + (detail.Length > 3000 ? detail[..3000] : detail) + "\n```");
    lines.Add(Words.Reply);
    return string.Join("\n\n", lines);
  }

  // ---- Sends, strictly one after another ----

  /// Formatted for WhatsApp (unless already), split at 4096, each piece after the one before. Only ever to `to`, which is
  /// always an inbound From (the creator).
  public void Send(string text, string to, bool format = true)
  {
    var pieces = WhatsAppText.Split(format ? WhatsAppText.Format(text) : text);
    lock (outGate) outbox = SendAfterAsync(outbox, pieces, to);
  }
  private async Task SendAfterAsync(Task previous, IReadOnlyList<string> pieces, string to)
  {
    try { await previous.ConfigureAwait(false); } catch (Exception) { }
    foreach (var piece in pieces)
    {
      for (var tries = 0; tries < 3; tries++)
      {
        WhatsAppSent result;
        try { result = await transport.SendAsync(key, to, piece).ConfigureAwait(false); }
        catch (Exception) { break; }
        if (result is WhatsAppSent.BackOff b) { await SleepAsync(Math.Max(1, b.Seconds)); continue; }
        break;
      }
    }
  }
  /// Waits until everything queued has been sent (tests, and a tool's send).
  public Task FlushedAsync() { lock (outGate) return outbox; }
}
