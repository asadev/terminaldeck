using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Integration;

// The transport binds this once per connection epoch and clears it before
// releasing that epoch's sealed channels. No polling or unsealed side channel.
public interface IW9PhonePushApplication
{
  void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publisher);
}

public sealed record W9PhoneHootGrant(string DeviceId, string Folder, string AccountId, bool Enabled);
public sealed record W9PhoneHootGrantState(W9PhoneHootGrant[] Grants);
public sealed class W9PhoneHootGrants(IStateStore<W9PhoneHootGrantState> store)
{
  private readonly object gate = new();
  private W9PhoneHootGrantState state = Validate(store.Load() ?? new([]));
  private static W9PhoneHootGrantState Validate(W9PhoneHootGrantState value)
  {
    if (value.Grants is null || value.Grants.Any(g => g is null || string.IsNullOrWhiteSpace(g.DeviceId) || string.IsNullOrWhiteSpace(g.AccountId)) || value.Grants.Select(g => g.DeviceId).Distinct().Count() != value.Grants.Length)
      throw new IOException("The saved phone Hoot access could not be read safely.");
    foreach (var grant in value.Grants) _ = ProjectPaths.Normalize(grant.Folder);
    return value;
  }
  public IReadOnlyList<W9PhoneHootGrant> List() { lock (gate) return state.Grants.ToArray(); }
  public void Set(W9PhoneHootGrant grant)
  {
    if (string.IsNullOrWhiteSpace(grant.DeviceId) || string.IsNullOrWhiteSpace(grant.AccountId)) throw new ArgumentException("Choose a phone and Hoot's account.");
    _ = ProjectPaths.Normalize(grant.Folder);
    lock (gate)
    {
      var next = new W9PhoneHootGrantState(state.Grants.Where(g => g.DeviceId != grant.DeviceId).Append(grant).ToArray());
      store.Save(next); state = next;
    }
  }
  public bool Allows(ApprovedDevice device, HootState hoot)
  {
    lock (gate) return hoot.Settings is { } settings && state.Grants.Any(g => g.DeviceId == device.Id && g.Enabled &&
      g.AccountId == settings.AccountId && ProjectPaths.Equal(g.Folder, settings.Folder));
  }
}

// Tasks are supplied by wrapping TaskPhoneApplication as next. Hoot uses the
// desktop's one owner and the same normalized events the unchanged phones read.
public sealed class W9PhoneApplication : IRelayPhoneApplication, IW9PhonePushApplication, IDisposable
{
  private sealed class Channel(string deviceId, byte[] key, bool events, bool accessUpdates, bool hootOffered)
  {
    public string DeviceId { get; } = deviceId;
    public byte[] Key { get; } = key;
    public bool Events { get; } = events;
    public bool AccessUpdates { get; } = accessUpdates;
    public bool HootOffered { get; } = hootOffered;
    public bool Attached { get; set; }
    public string ConnectionId { get; } = Guid.NewGuid().ToString("N");
    public SemaphoreSlim PushGate { get; } = new(1, 1);
  }
  private readonly IRelayPhoneApplication next;
  private readonly DeviceTrust trust;
  private readonly IHoot hoot;
  private readonly IPhoneSessionView sessions;
  private readonly Func<ApprovedDevice, HootState, bool> canUseHoot;
  private readonly ReceiverPhoneIntake? receiver;
  private readonly Func<CancellationToken, ValueTask<HootState>> readHoot;
  private readonly ConcurrentDictionary<string, Channel> channels = new();
  private readonly ConcurrentDictionary<string, string> turnOwners = new();
  private Func<string, byte[], CancellationToken, ValueTask>? publisher;
  private bool disposed;
  public W9PhoneApplication(IRelayPhoneApplication next, DeviceTrust trust, IHoot hoot, IPhoneSessionView sessions,
    Func<ApprovedDevice, HootState, bool> canUseHoot, ReceiverPhoneIntake? receiver = null,
    Func<CancellationToken, ValueTask<HootState>>? readHoot = null)
  {
    this.next = next; this.trust = trust; this.hoot = hoot; this.sessions = sessions;
    this.canUseHoot = canUseHoot; this.receiver = receiver; this.readHoot = readHoot ?? (_ => ValueTask.FromResult(hoot.Read())); hoot.Changed += Changed; trust.Changed += TrustChanged;
  }
  public IReadOnlyCollection<byte[]> KnownPeers => next.KnownPeers;
  public bool PairingOpen => next.PairingOpen;
  public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publish) => Volatile.Write(ref publisher, publish);
  public ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> peerKey, CancellationToken ct) => next.OpenedAsync(channel, peerKey, ct);
  public async ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, CancellationToken ct)
  {
    ObjectDisposedException.ThrowIf(disposed, this); ct.ThrowIfCancellationRequested();
    var message = Parse(plaintext); var type = Text(message, "t", 64);
    // Android still writes copilot.*; the Mac accepts this spelling too.
    if (type.StartsWith("copilot.", StringComparison.Ordinal)) type = "hoot." + type[8..];
    channels.TryGetValue(channel, out var expected);
    if (type != "hello" && expected is null) throw new ProtocolException("Say hello before using this connection.");
    HootState fresh;
    try { fresh = await readHoot(ct); }
    catch (Exception ex) when (ex is IOException or TimeoutException)
    {
      // The cached desk is history, never a live keeper snapshot. Closing the
      // channel forces a new authenticated welcome and grants after recovery.
      return new([JsonSerializer.SerializeToUtf8Bytes(new { t = "hoot.state", state = new { desk = "reconnecting", available = false,
        pending = 0, grant = new { read = false, act = false, alter = false }, recovery = PhoneRecovery.Describe(null, false) } }),
        JsonSerializer.SerializeToUtf8Bytes(new { t = "error", code = "reconnecting", message = "This computer is reconnecting. Retry the connection; check your last message before sending again." })], Close: true);
    }
    if (type != "hello" && (!channels.TryGetValue(channel, out var currentLink) || !ReferenceEquals(expected, currentLink)))
      throw new ProtocolException("Reconnect this phone before continuing.");
    if (type == "hello")
    {
      if (channels.ContainsKey(channel)) throw new ProtocolException("This connection already said hello.");
      var reply = await next.ReceiveAsync(channel, peerKey, plaintext, ct);
      if (reply.Close) return reply;
      var current = trust.Authenticate(Text(message, "token", 200), peerKey.Span);
      var events = message.TryGetProperty("capabilities", out var caps) && caps.ValueKind == JsonValueKind.Array &&
        caps.EnumerateArray().Any(c => c.ValueKind == JsonValueKind.String && c.GetString() == "hoot.events");
      var accessUpdates = caps.ValueKind == JsonValueKind.Array && caps.EnumerateArray().Any(c => c.ValueKind == JsonValueKind.String && c.GetString() == "device.access");
      var allowed = canUseHoot(current, fresh) && Volatile.Read(ref publisher) is not null;
      var opened = new Channel(current.Id, peerKey.ToArray(), events, accessUpdates, allowed);
      var messages = reply.Messages.Select(raw =>
      {
        var root = JsonNode.Parse(raw);
        if (root?["t"]?.GetValue<string>() != "welcome") return raw;
        var capabilities = root["capabilities"]?.Deserialize<string[]>() ?? [];
        if (accessUpdates) capabilities = [.. capabilities, "device.access"];
        if (allowed)
        {
          capabilities = [.. capabilities, "hoot", "hoot.events", "hoot.recovery"];
          root["hoot"] = JsonSerializer.SerializeToNode(new { linked = true, open = false, grant = Grant(current), recovery = Recovery(opened) });
        }
        root["capabilities"] = JsonSerializer.SerializeToNode(capabilities.Distinct());
        // Receiver intake holds drafts for approval; it does not pretend to be
        // the Mac's full send capability (which also promises upload/report).
        return JsonSerializer.SerializeToUtf8Bytes(root);
      }).ToList();
      current = trust.RequireCurrent(current.Id, peerKey.Span);
      // Android and iOS reset their access on welcome. The negotiated access
      // frame must follow it; capabilities alone cannot unlock a task read.
      if (accessUpdates)
      {
        var welcome = messages.FindIndex(raw => Parse(raw).GetProperty("t").GetString() == "welcome");
        if (welcome >= 0) messages.Insert(welcome + 1, AccessFrame(current));
      }
      channels[channel] = opened;
      return new(messages);
    }
    if (!type.StartsWith("hoot.", StringComparison.Ordinal) && !(type == "session.send" && receiver is not null))
      return await next.ReceiveAsync(channel, peerKey, plaintext, ct);
    if (!channels.TryGetValue(channel, out var link)) throw new ProtocolException("Say hello before using this connection.");
    if (!peerKey.Span.SequenceEqual(link.Key)) throw new ProtocolException("Reconnect this phone before continuing.");
    var device = trust.RequireCurrent(link.DeviceId, peerKey.Span);
    if (type == "session.send") return new([receiver!.SendToSession(device, plaintext.Span)]);
    var state = fresh; RequireHoot(device, state, type);
    switch (type)
    {
      case "hoot.hello": return Reply(new { t = "hoot.grant", link = new { linked = true, open = true, grant = Grant(device), recovery = Recovery(link) } });
      case "hoot.bye": case "hoot.detach": link.Attached = false; return new([]);
      case "hoot.attach":
        if (!link.Events || Volatile.Read(ref publisher) is null) throw new ProtocolException("This connection cannot watch Hoot's conversation.");
        link.Attached = true; return new([Snapshot(state, link)]);
      case "hoot.older": return new([Page(state, Whole(message, "before", 0, 1000000))]);
      case "hoot.state": return Reply(new { t = "hoot.state", state = new { desk = state.ChatId is null ? "stopped" : "running", run = state.ChatId,
        profile = state.Settings?.AccountId, available = state.Settings is not null, reason = state.Problem, pending = Pending(state, device).Length, grant = Grant(device), recovery = Recovery(link) } });
      case "hoot.recovery": return Reply(new { t = "hoot.recovery", recovery = Recovery(link) });
      case "hoot.sessions": return Reply(new { t = "hoot.sessions", sessions = sessions.Read(device) });
      case "hoot.pending": return Reply(new { t = "hoot.pending", questions = Pending(state, device) });
      case "hoot.log":
        var limit = message.TryGetProperty("limit", out _) ? Whole(message, "limit", 1, 200) : 100;
        return Reply(new { t = "hoot.log", rows = state.Turns.TakeLast(limit).Select(t => new { id = t.Id, at = t.At.ToString("O"), tool = t.Source.Kind, detail = Clip(t.Text, 200), outcome = t.State is HootTurnState.Failed or HootTurnState.Uncertain ? "error" : "ok" }), more = state.Turns.Length > limit });
      case "hoot.start": await hoot.ContinueAsync(ct); await hoot.StartAsync(ct); return new([]);
      case "hoot.say":
        var text = Text(message, "text", 16384, controls: true);
        var turn = Guid.NewGuid().ToString(); turnOwners[turn] = device.Id;
        try { await hoot.SayAsync(turn, text, cancellationToken: ct); }
        catch { turnOwners.TryRemove(turn, out _); throw; }
        return new([]);
      case "hoot.cancel": case "hoot.stop": await hoot.StopAsync(ct); return new([]);
      case "hoot.answer":
        var request = Text(message, "id", 128);
        if (!state.Lines.Any(l => l.Kind == "approval" && l.Waiting && l.RequestId == request && l.TurnId is not null && turnOwners.GetValueOrDefault(l.TurnId) == device.Id))
          throw new ProtocolException("This confirmation expired or belongs to another caller.");
        if (!message.TryGetProperty("approved", out var approved) || approved.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new ProtocolException("Choose allow or refuse.");
        await hoot.AnswerAsync(request, approved.GetBoolean(), ct);
        return Reply(new { t = "hoot.pending", questions = Pending(await readHoot(ct), device) });
      // The Windows owner has no scan mode or file editor. Never call a
      // settings operation here or treat an unknown operation as successful.
      default: throw new ProtocolException("This Hoot action is not available on this computer.");
    }
  }
  private void RequireHoot(ApprovedDevice device, HootState state, string type)
  {
    if (!canUseHoot(device, state)) throw new ProtocolException("Hoot is not shared with this phone.");
    // The Windows chat owner has no per-turn remote tier context yet. Only a
    // Full phone may spend an owner turn; Work remains read-only here.
    if ((type is "hoot.start" or "hoot.say" or "hoot.cancel" or "hoot.stop") && device.Access != PhoneAccess.Full)
      throw new ProtocolException("This phone can watch Hoot but cannot control it.");
    if (type == "hoot.answer" && device.Access != PhoneAccess.Full) throw new ProtocolException("This phone cannot answer confirmations.");
  }
  // Phones that understand this capability must use these flags for their
  // recovery controls. Older clients retain explicit refusals for unsupported
  // taps rather than an acknowledgement that pretends an action succeeded.
  private static object Recovery(Channel link) => PhoneRecovery.Describe(link.ConnectionId, true);
  private static byte[] Snapshot(HootState state, Channel link) => Page(state, recovery: Recovery(link));
  private static object Grant(ApprovedDevice device) => new { read = true, act = device.Access == PhoneAccess.Full, alter = device.Access == PhoneAccess.Full };
  private object[] Pending(HootState state, ApprovedDevice device) => device.Access != PhoneAccess.Full ? [] : state.Lines
    .Where(l => l.Kind == "approval" && l.Waiting && l.RequestId is not null && l.TurnId is not null && turnOwners.GetValueOrDefault(l.TurnId) == device.Id)
    .Select(l => (object)new { id = l.RequestId, tool = "hoot.cli", summary = l.Text, requestedAt = l.At.ToUnixTimeMilliseconds(), args = new { }, tier = "alter", mine = true }).ToArray();
  private void Changed(HootState state)
  {
    foreach (var pair in channels.Where(p => p.Value.Attached)) _ = PushAsync(pair.Key, pair.Value);
  }
  private void TrustChanged()
  {
    foreach (var pair in channels.Where(p => p.Value.AccessUpdates)) _ = PushAccessAsync(pair.Key, pair.Value);
  }
  private async Task PushAccessAsync(string channel, Channel link)
  {
    await link.PushGate.WaitAsync();
    try
    {
      if (!channels.TryGetValue(channel, out var current) || !ReferenceEquals(link, current)) return;
      var publish = Volatile.Read(ref publisher); if (publish is null) return;
      ApprovedDevice? device;
      try { device = trust.RequireCurrent(link.DeviceId, link.Key); }
      catch (ProtocolException) { device = null; }
      await publish(channel, AccessFrame(device), CancellationToken.None);
      if (link.HootOffered)
      {
        // Hoot uses the same current device access, plus its separate grant.
        // Downgrading a phone must also remove the Hoot composer immediately.
        var allowed = device is not null && canUseHoot(device, await readHoot(CancellationToken.None));
        if (!allowed) link.Attached = false;
        var grant = allowed ? Grant(device!) : new { read = false, act = false, alter = false };
        await publish(channel, JsonSerializer.SerializeToUtf8Bytes(new { t = "hoot.grant", link = new { linked = allowed, open = link.Attached, grant } }), CancellationToken.None);
      }
    }
    catch (Exception ex) when (ex is ProtocolException or IOException or OperationCanceledException or ObjectDisposedException or System.Net.WebSockets.WebSocketException)
    { await InvalidateAsync(channel, link); }
    finally { link.PushGate.Release(); }
  }
  private static byte[] AccessFrame(ApprovedDevice? device) => JsonSerializer.SerializeToUtf8Bytes(new
  { t = "device.access", level = device?.Access.ToString().ToLowerInvariant() });
  private async Task PushAsync(string channel, Channel link)
  {
    await link.PushGate.WaitAsync();
    try
    {
      if (!link.Attached || !channels.TryGetValue(channel, out var current) || !ReferenceEquals(link, current)) return;
      var state = await readHoot(CancellationToken.None);
      if (!link.Attached || !channels.TryGetValue(channel, out current) || !ReferenceEquals(link, current)) return;
      var device = trust.RequireCurrent(link.DeviceId, link.Key);
      RequireHoot(device, state, "hoot.attach");
      var publish = Volatile.Read(ref publisher);
      if (publish is not null)
      {
        await publish(channel, Snapshot(state, link), CancellationToken.None);
        // Confirmation ownership remains in the owner service. A stream row
        // alone never authorizes an answer on a second phone.
        device = trust.RequireCurrent(link.DeviceId, link.Key); RequireHoot(device, await readHoot(CancellationToken.None), "hoot.pending");
        await publish(channel, JsonSerializer.SerializeToUtf8Bytes(new { t = "hoot.pending", questions = Pending(state, device) }), CancellationToken.None);
      }
    }
    catch (Exception ex) when (ex is ProtocolException or IOException or OperationCanceledException or ObjectDisposedException or System.Net.WebSockets.WebSocketException)
    { await InvalidateAsync(channel, link); }
    finally { link.PushGate.Release(); }
  }
  private async ValueTask InvalidateAsync(string channel, Channel link)
  {
    link.Attached = false;
    if (!channels.TryGetValue(channel, out var current) || !ReferenceEquals(link, current)) return;
    var publish = Volatile.Read(ref publisher); if (publish is null) return;
    try
    {
      await publish(channel, JsonSerializer.SerializeToUtf8Bytes(new { t = "hoot.grant", link = new { linked = false, open = false,
        grant = new { read = false, act = false, alter = false }, recovery = PhoneRecovery.Describe(link.ConnectionId, false) } }), CancellationToken.None);
      await publish(channel, JsonSerializer.SerializeToUtf8Bytes(new { t = "hoot.pending", questions = Array.Empty<object>() }), CancellationToken.None);
    }
    catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException or System.Net.WebSockets.WebSocketException) { }
  }
  public async ValueTask DisconnectedAsync(string channel)
  {
    if (channels.TryRemove(channel, out var link)) link.Attached = false;
    await next.DisconnectedAsync(channel);
  }
  public void Dispose() { disposed = true; hoot.Changed -= Changed; trust.Changed -= TrustChanged; SetPublisher(null); foreach (var link in channels.Values) link.Attached = false; channels.Clear(); }
  public static byte[] Page(HootState state, int? before = null, object? recovery = null)
  {
    var end = Math.Clamp(before ?? state.Lines.Length, 0, state.Lines.Length); var first = Math.Max(0, end - 598);
    var lines = state.Lines.OrderBy(l => l.Sequence).ToArray();
    // Phones acknowledge optimistic user bubbles only for events newer than
    // their last sequence, even when a full snapshot resets the display. Keep
    // room after each line for its problem/completion so neither can steal the
    // next user's position. Revision also advances a streamed answer's event.
    static long Position(HootLine line) => Math.Max(line.Sequence, line.Revision);
    var events = lines[first..end].Select(line => JsonSerializer.SerializeToElement(new { version = 1, id = state.ConversationId + ":" + Position(line) * 3,
      sequence = Position(line) * 3, at = line.At.ToUnixTimeMilliseconds(), turnId = line.TurnId,
      conversationId = state.ConversationId, kind = Kind(line), messageId = line.Id,
      value = new { text = Clip(line.Text, 6000), requestId = line.RequestId, input = Clip(line.Details, 2000) } })).ToList();
    if (before is null)
    {
      var turn = state.Turns.LastOrDefault();
      var tail = Math.Max(state.Revision, lines.Length == 0 ? 0 : lines.Max(Position)) * 3;
      var problem = state.Problem ?? turn?.Problem;
      if (!string.IsNullOrWhiteSpace(problem) && !lines.Any(l => l.Kind == "error" && l.TurnId == turn?.Id && l.Text == problem))
        events.Add(JsonSerializer.SerializeToElement(new { version = 1, id = state.ConversationId + ":" + (tail + 1), sequence = tail + 1,
          at = turn?.At.ToUnixTimeMilliseconds() ?? 0, turnId = turn?.Id, conversationId = state.ConversationId, kind = "error",
          messageId = "problem:" + (turn?.Id ?? state.ConversationId), value = new { text = Clip(problem, 6000), isError = true, status = "failed" } }));
      // Queued is not finished. Sending completion between the user's echo
      // and dispatch makes an unchanged phone report a silent finished turn.
      if (!state.Busy && state.Waiting == 0 && turn is { State: HootTurnState.Finished or HootTurnState.Failed or HootTurnState.Stopped or HootTurnState.Uncertain })
        events.Add(JsonSerializer.SerializeToElement(new { version = 1, id = state.ConversationId + ":" + (tail + 2), sequence = tail + 2,
          at = turn.At.ToUnixTimeMilliseconds(), turnId = turn.Id, conversationId = state.ConversationId, kind = "completed",
          messageId = "complete:" + turn.Id, value = new { text = "" } }));
    }
    var sizes = events.Select(e => JsonSerializer.SerializeToUtf8Bytes(e).Length + 1).ToArray(); var budget = sizes.Sum(); var drop = 0;
    while (budget > PhoneWire.MaximumMessageBytes - 2048 && drop < end - first) { budget -= sizes[drop++]; }
    events.RemoveRange(0, drop); first += drop;
    while (true)
    {
      var page = JsonSerializer.SerializeToUtf8Bytes(new { t = "hoot.events", conversationId = state.ConversationId, reset = before is null, older = before is not null, first, total = lines.Length, events, recovery });
      if (page.Length <= PhoneWire.MaximumMessageBytes) return page;
      if (first >= end) throw new ProtocolException("Hoot's conversation is too large for this phone.");
      events.RemoveAt(0); first++;
    }
  }
  private static string Kind(HootLine line) => line.Kind switch { "user" => "user", "assistant" => "message", "tool" => "toolResult", "approval" => line.Waiting ? "approval" : "approvalResolved", "error" => "error", _ => "message" };
  private static string Clip(string value, int limit) => value.Length <= limit ? value : value[..limit] + "\n[Read the rest on the computer.]";
  private static PhoneApplicationReply Reply(object message) => new([JsonSerializer.SerializeToUtf8Bytes(message)]);
  private static JsonElement Parse(ReadOnlyMemory<byte> bytes)
  {
    if (bytes.Length > PhoneWire.MaximumMessageBytes) throw new ProtocolException("The phone message is too large.");
    try
    {
      _ = new UTF8Encoding(false, true).GetString(bytes.Span);
      using var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
      var root = doc.RootElement;
      if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Select(p => p.Name).Distinct().Count() != root.EnumerateObject().Count()) throw new JsonException();
      return root.Clone();
    }
    catch (Exception ex) when (ex is JsonException or DecoderFallbackException) { throw new ProtocolException("The phone message is unusable."); }
  }
  private static string Text(JsonElement message, string key, int limit, bool controls = false)
  {
    if (!message.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String) throw new ProtocolException("The phone message is missing a field.");
    var text = value.GetString()!;
    if (text.Length == 0 || Encoding.UTF8.GetByteCount(text) > limit || (!controls && text.Any(char.IsControl))) throw new ProtocolException("The phone message has an unusable field.");
    return text;
  }
  private static int Whole(JsonElement message, string key, int min, int max)
  {
    if (!message.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number) || number < min || number > max) throw new ProtocolException("The phone message has an unusable number.");
    return number;
  }
}
