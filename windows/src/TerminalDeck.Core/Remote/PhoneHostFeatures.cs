using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Remote;

// What the phone features read and do on this PC (the App supplies it).
public interface IPhoneHostSessions
{
  IReadOnlyList<SessionRecord> Terminals();
  IReadOnlyList<ChatRecord> Chats();
  bool Visible(ApprovedDevice device, SessionRecord terminal);
  bool Visible(ApprovedDevice device, ChatRecord chat);
  // Folders this phone is offered for a new session (the welcome's `folders`).
  IReadOnlyList<string> Folders(ApprovedDevice device);
  bool MayStartIn(ApprovedDevice device, string folder);
  ValueTask<SessionRecord> StartTerminalAsync(string provider, string folder, string? accountId, CancellationToken ct);
  ValueTask<ChatRecord> StartChatAsync(string provider, string folder, string? accountId, ChatOptions options, AiPermissionMode? mode, CancellationToken ct);
  ValueTask CloseAsync(string id, CancellationToken ct);
  ValueTask RenameAsync(string id, string title, CancellationToken ct);
  ValueTask<KeeperRemoteAttachment> AttachAsync(string id, CancellationToken ct);
  ValueTask WriteAsync(string id, string data, CancellationToken ct);
  ValueTask ResizeAsync(string id, TerminalSize size, CancellationToken ct);
  string? ObservedStatus(SessionRecord session) => null;
  IChatSessions? ChatEngine { get; }
  bool SupportsAttachments => false;
  ValueTask<ChatAttachmentData[]> AttachmentsAsync(ApprovedDevice device, IReadOnlyList<string> paths, CancellationToken ct) => ValueTask.FromException<ChatAttachmentData[]>(new PhoneRefusal("unavailable", "Attachments are not connected."));
  IReadOnlyList<(string Id, string Name)> TerminalProviders() => [];
  IReadOnlyList<AccountProfile> Accounts();
  AccountProfile? PreferredAccount(string provider, string folder);
  AiPermissionMode NewChatPermission(string provider);
  // Sessions or chats changed (raised often; the phones get a list only when theirs changed).
  event Action? Changed;
}

// The phone features a Mac host serves, on this PC: every session and agent chat
// (`chats`), opening a terminal and typing, New session / Close / Rename, the
// Activity page (`activity`), This PC's screen (`sims`), and a plain answer to a
// message this PC does not know instead of a closed connection. It wraps the
// existing chain (Hoot, Tasks, pairing) and passes their messages on unchanged.
public sealed class PhoneHostFeatures : IRelayPhoneApplication, IW9PhonePushApplication, IDisposable
{
  private sealed class Link(string deviceId, byte[] key, HashSet<string> capabilities)
  {
    public string DeviceId { get; } = deviceId;
    public byte[] Key { get; } = key;
    public HashSet<string> Capabilities { get; } = capabilities;
    public readonly ConcurrentDictionary<string, CancellationTokenSource> Attached = new();
    public readonly ConcurrentDictionary<string, string> WatchedChats = new();
    public readonly CancellationTokenSource Life = new();
    public string LastSessions = "";
  }

  // Messages the wrapped chain answers (Hoot, Tasks, the Receiver, pairing).
  private static bool Inner(string type, JsonElement message) =>
    type is "hello" or "ping" or "session.send" || type.StartsWith("hoot.", StringComparison.Ordinal) || type.StartsWith("copilot.", StringComparison.Ordinal) ||
    type == "panel.read" && message.TryGetProperty("panel", out var panel) && panel.ValueKind == JsonValueKind.String && panel.GetString() == "tasks";

  // BackendINT2PhoneAccessLevel.permits: reads at every level; Work adds these; the rest is Full control.
  private static readonly HashSet<string> Reads = ["list", "attach", "detach", "resize", "take", "activity.watch", "activity.unwatch",
    "chats.watch", "chats.unwatch", "chats.older", "chats.choices", "chats.options", "sims.list", "sims.watch", "sims.unwatch", "sims.ack", "sims.key", "sims.shot"];
  private static readonly HashSet<string> WorkMessages = ["input", "create", "close", "rename", "chats.say", "chats.steer", "chats.new", "chats.interrupt",
    "chats.set", "sims.input", "sims.power", "sims.annotate"];

  private readonly IRelayPhoneApplication next;
  private readonly DeviceTrust trust;
  private readonly IPhoneHostSessions host;
  private readonly PhoneActivityStream? activity;
  private readonly PhoneScreens? screens;
  private readonly IPhoneHostWorkspace? workspace;
  private readonly ConcurrentDictionary<string, Link> links = new();
  private readonly ConcurrentDictionary<string, long> lastOutput = new();
  private Func<string, byte[], CancellationToken, ValueTask>? publisher;
  private int broadcastQueued;
  private bool disposed;

  public PhoneHostFeatures(IRelayPhoneApplication next, DeviceTrust trust, IPhoneHostSessions host, ISystemActivityReader? activity = null, PhoneScreens? screens = null, IPhoneHostWorkspace? workspace = null)
  {
    this.next = next; this.trust = trust; this.host = host; this.screens = screens; this.workspace = workspace;
    this.activity = activity is null ? null : new PhoneActivityStream(activity, PublishAsync);
    screens?.Bind(PublishAsync, DeviceFor);
    workspace?.Bind((channel, message, ct) => PublishAsync(channel, Json(message)), DeviceFor);
    host.Changed += Changed; trust.Changed += Changed;
  }

  public IReadOnlyCollection<byte[]> KnownPeers => next.KnownPeers;
  public bool PairingOpen => next.PairingOpen;
  public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publish)
  {
    Volatile.Write(ref publisher, publish);
    if (next is IW9PhonePushApplication inner) inner.SetPublisher(publish);
  }
  public ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> peerKey, CancellationToken ct) => next.OpenedAsync(channel, peerKey, ct);

  public async ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, CancellationToken ct)
  {
    ObjectDisposedException.ThrowIf(disposed, this); ct.ThrowIfCancellationRequested();
    var message = Parse(plaintext);
    if (!message.TryGetProperty("t", out var t) || t.ValueKind != JsonValueKind.String || t.GetString() is not { Length: > 0 and <= 64 } type)
      return Reply(Error("bad-message", "unknown message type"));
    if (type == "hello") return await HelloAsync(channel, peerKey, plaintext, message, ct);
    if (Inner(type, message))
    {
      if (type is not ("panel.read" or "panel.act")) return await next.ReceiveAsync(channel, peerKey, plaintext, ct);
      var innerRid = message.TryGetProperty("rid", out var ir) && ir.ValueKind == JsonValueKind.String ? ir.GetString() : null;
      try
      {
        _ = PhonePanelPagination.Cursor(message);
        var reply = await next.ReceiveAsync(channel, peerKey, plaintext, ct);
        return reply with { Messages = reply.Messages.Select(raw => JsonNode.Parse(raw) is JsonObject frame && frame["t"]?.GetValue<string>() == "panel.rows" ? Json(PhonePanelPagination.Apply(message, frame, innerRid)) : raw).ToArray() };
      }
      catch (PhoneRefusal refusal) { return Reply(Error(refusal.Code, refusal.Message, innerRid)); }
      catch (ProtocolException ex) { return Reply(Error("unauthorized", Plain(ex.Message), innerRid)); }
    }
    if (!links.TryGetValue(channel, out var link)) throw new ProtocolException("Say hello before using this connection.");
    if (!peerKey.Span.SequenceEqual(link.Key)) throw new ProtocolException("Reconnect this phone before continuing.");
    var device = trust.RequireCurrent(link.DeviceId, peerKey.Span);
    var rid = message.TryGetProperty("rid", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString() : null;
    if (!Known(type))
    {
      if (type == "panel.read") return Reply(Error("unavailable", "That page is not on this computer yet.", rid));
      // The Mac's words, so a phone counts it and says "update" instead of looping; the connection stays open.
      var named = System.Text.RegularExpressions.Regex.IsMatch(type, "^[a-z][a-z0-9.-]{0,63}$");
      return Reply(Error("bad-message", named ? "unknown message type: " + type : "unknown message type", rid));
    }
    // The trackpad's moves, clicks and scrolls carry no request id: nothing waits for an answer, so a refusal of
    // one is never said over the picture (the Mac's round-3 rule); the phone already shows why it cannot control.
    var silent = type == "sims.input" && rid is null;
    if (!Permits(device.Access, type)) return silent ? new([]) : Reply(Error("unauthorized", "This device's current host access does not permit that action.", rid));
    try { if (type is "panel.read" or "panel.act") _ = PhonePanelPagination.Cursor(message); return await DispatchAsync(channel, link, device, type, message, rid, ct); }
    catch (PhoneRefusal refusal) { return silent ? new([]) : Reply(Error(refusal.Code, refusal.Message, rid)); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or KeyNotFoundException or TimeoutException or NotSupportedException or UnauthorizedAccessException)
    { return silent ? new([]) : Reply(Error("unavailable", Plain(ex.Message), rid)); }
    catch (Exception ex) when (ex is not ProtocolException and not OperationCanceledException)
    {
      // Anything else is answered too (the Mac's rule): one bad path must never stop the relay for every phone.
      System.Diagnostics.Trace.WriteLine("Phone " + type + " failed: " + ex.GetType().Name + ": " + ex.Message);
      return silent ? new([]) : Reply(Error("unavailable", "That did not work on this computer.", rid));
    }
  }

  private bool Known(string type) => Reads.Contains(type) || WorkMessages.Contains(type) || type == "chats.answer" || type == "sims.record" || workspace?.Handles(type) == true;
  private bool Permits(PhoneAccess access, string type) =>
    (access == PhoneAccess.Hoot ? type == "list" || type.StartsWith("upload.", StringComparison.Ordinal) && workspace?.Handles(type) == true && workspace.Permits(access, type) : (workspace?.Handles(type) == true ? workspace.Permits(access, type) : Reads.Contains(type) || access == PhoneAccess.Full || access == PhoneAccess.Work && WorkMessages.Contains(type)));

  private async ValueTask<PhoneApplicationReply> HelloAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, JsonElement message, CancellationToken ct)
  {
    if (links.ContainsKey(channel)) throw new ProtocolException("This connection already said hello.");
    var reply = await next.ReceiveAsync(channel, peerKey, plaintext, ct);
    if (reply.Close) return reply;
    if (!message.TryGetProperty("token", out var token) || token.ValueKind != JsonValueKind.String) return reply;
    var device = trust.Authenticate(token.GetString()!, peerKey.Span);
    var claimed = message.TryGetProperty("capabilities", out var caps) && caps.ValueKind == JsonValueKind.Array
      ? caps.EnumerateArray().Where(c => c.ValueKind == JsonValueKind.String).Select(c => c.GetString()!).ToHashSet() : [];
    var link = new Link(device.Id, peerKey.ToArray(), claimed);
    var messages = reply.Messages.Select(raw =>
    {
      try { return Welcome(raw, device, link); }
      catch (Exception ex) when (ex is not OperationCanceledException)
      {
        // A welcome this layer cannot extend goes out as the chain wrote it: the phone still connects.
        System.Diagnostics.Trace.WriteLine("Phone welcome kept unchanged: " + ex.Message);
        return raw;
      }
    }).ToList();
    links[channel] = link;
    return new(messages);
  }

  private byte[] Welcome(byte[] raw, ApprovedDevice device, Link link)
  {
      var root = JsonNode.Parse(raw);
      if (root?["t"]?.GetValue<string>() != "welcome") return raw;
      var offered = root["capabilities"]?.Deserialize<string[]>() ?? [];
      var added = new List<string> { "create", "close", "rename", "chats" };
      if (host.SupportsAttachments) added.Add("chats.files");
      if (activity is not null) added.Add("activity");
      if (screens is not null && !string.Equals(device.Platform, "web", StringComparison.OrdinalIgnoreCase)) { added.Add("sims"); if (screens.CanRecord) added.Add("sims.record"); }
      if (workspace is not null) added.AddRange(workspace.Capabilities);
      var capabilities = offered.Concat(added).Distinct().ToArray();
      if (device.Access == PhoneAccess.Hoot) capabilities = capabilities.Where(c => c == "device.access" || c == "upload" && host.SupportsAttachments || c.StartsWith("hoot", StringComparison.Ordinal)).ToArray();
      root["capabilities"] = JsonSerializer.SerializeToNode(capabilities);
      var rows = Rows(device); link.LastSessions = Shape(rows);
      root["sessions"] = device.Access == PhoneAccess.Hoot ? new JsonArray() : rows;
      var folders = (root["folders"]?.Deserialize<string[]>() ?? []).Concat(host.Folders(device)).Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToArray();
      root["folders"] = device.Access == PhoneAccess.Hoot ? new JsonArray() : JsonSerializer.SerializeToNode(folders);
      return JsonSerializer.SerializeToUtf8Bytes(root);
  }

  private async ValueTask<PhoneApplicationReply> DispatchAsync(string channel, Link link, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    switch (type)
    {
      case "list": return Reply(Sessions(device, link));
      case "attach": case "take": return await AttachAsync(channel, link, device, message, ct);
      case "detach":
      {
        var id = Id(message, "id");
        if (link.Attached.TryRemove(id, out var stop)) { stop.Cancel(); stop.Dispose(); }
        return Reply(new JsonObject { ["t"] = "detached", ["id"] = id });
      }
      case "input":
      {
        var id = Id(message, "id");
        if (!link.Attached.ContainsKey(id)) return Reply(Unknown(id));
        if (Terminal(device, id) is null) return Reply(Error("unauthorized", "That session is no longer shared with this phone."));
        var data = Text(message, "data", PhoneWire.MaximumInputBytes, empty: true, controls: true);
        await host.WriteAsync(id, data, ct); return new([]);
      }
      case "resize":
      {
        var id = Id(message, "id");
        if (!link.Attached.ContainsKey(id)) return Reply(Unknown(id));
        if (Terminal(device, id) is null) return Reply(Unknown(id));
        await host.ResizeAsync(id, Size(message) ?? throw new PhoneRefusal("bad-message", "resize without a size"), ct); return new([]);
      }
      case "create": return await CreateAsync(device, link, message, ct);
      case "close":
      {
        var id = Id(message, "id");
        if (Terminal(device, id) is null && Chat(device, id) is null) return Reply(Unknown(id));
        await host.CloseAsync(id, ct); QueueBroadcast();
        return Reply(new JsonObject { ["t"] = "closed", ["id"] = id });
      }
      case "rename":
      {
        var id = Id(message, "id");
        if (Terminal(device, id) is null && Chat(device, id) is null) return Reply(Unknown(id));
        var title = Text(message, "title", 120, empty: false).Trim();
        await host.RenameAsync(id, title, ct); QueueBroadcast(); return new([]);
      }
      case "activity.watch":
        if (activity is null) throw new PhoneRefusal("unavailable", "This computer does not offer its activity.");
        return Reply(activity.Watch(channel, !message.TryGetProperty("top", out var top) || top.ValueKind != JsonValueKind.False));
      case "activity.unwatch": activity?.Unwatch(channel); return new([]);
      default:
        if (workspace?.Handles(type) == true) return new((await workspace.HandleAsync(channel, device, type, message, rid, ct)).Select(m => JsonSerializer.SerializeToUtf8Bytes(m)).ToArray());
        if (type.StartsWith("chats.", StringComparison.Ordinal)) return await ChatsAsync(link, device, type, message, rid, ct);
        if (type.StartsWith("sims.", StringComparison.Ordinal))
        {
          if (screens is null) throw new PhoneRefusal("unavailable", "This computer does not offer its screen.");
          return new((await screens.HandleAsync(channel, device, type, message, rid, ct)).Select(m => JsonSerializer.SerializeToUtf8Bytes(m)).ToArray());
        }
        throw new PhoneRefusal("bad-message", "unknown message type: " + type);
    }
  }

  // ---- terminals -------------------------------------------------------------------------------

  private async ValueTask<PhoneApplicationReply> AttachAsync(string channel, Link link, ApprovedDevice device, JsonElement message, CancellationToken ct)
  {
    var id = Id(message, "id");
    if (Terminal(device, id) is not { } session) return Reply(Unknown(id));
    if (session.State == SessionState.Exited) return Reply(Unknown(id));
    // With a size, this phone takes the session's size (the Mac's 28 Oct rule); a picture-only phone sends none.
    if (Size(message) is { } size) await host.ResizeAsync(id, size, ct);
    var attachment = await host.AttachAsync(id, ct);
    var frames = new List<byte[]> { Json(new JsonObject { ["t"] = "attached", ["id"] = id }) };
    foreach (var chunk in PhoneWire.OutputChunks(attachment.Snapshot.Replay))
      frames.Add(Json(new JsonObject { ["t"] = "output", ["id"] = id, ["data"] = chunk, ["replay"] = true }));
    frames.Add(Json(Status(session)));
    if (link.Attached.TryRemove(id, out var old)) { old.Cancel(); old.Dispose(); }
    var stop = CancellationTokenSource.CreateLinkedTokenSource(link.Life.Token);
    link.Attached[id] = stop;
    _ = PumpAsync(channel, link, id, attachment, stop.Token);
    return new(frames);
  }

  private async Task PumpAsync(string channel, Link link, string id, KeeperRemoteAttachment attachment, CancellationToken ct)
  {
    await Task.Yield();
    try
    {
      await using (attachment)
        await foreach (var change in attachment.Events(ct))
        {
          switch (change.Kind)
          {
            case "data" when change.Text is { Length: > 0 } text:
              var wasQuiet = !Working(id);
              lastOutput[id] = Environment.TickCount64;
              foreach (var chunk in PhoneWire.OutputChunks(text)) await PublishAsync(channel, Json(new JsonObject { ["t"] = "output", ["id"] = id, ["data"] = chunk }));
              if (wasQuiet) await PublishAsync(channel, Json(new JsonObject { ["t"] = "status", ["id"] = id, ["status"] = host.Terminals().FirstOrDefault(s => s.Definition.Id == id) is { } observed ? host.ObservedStatus(observed) ?? "working" : "working", ["lastActivityAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() }));
              break;
            case "reset":
              // A device's terminal starts clean from `attached` each time.
              await PublishAsync(channel, Json(new JsonObject { ["t"] = "attached", ["id"] = id }));
              foreach (var chunk in PhoneWire.OutputChunks(change.Text ?? "")) await PublishAsync(channel, Json(new JsonObject { ["t"] = "output", ["id"] = id, ["data"] = chunk, ["replay"] = true }));
              break;
            case "exit":
              await PublishAsync(channel, Json(new JsonObject { ["t"] = "exit", ["id"] = id, ["exitCode"] = change.ExitCode ?? 0 }));
              link.Attached.TryRemove(id, out _); QueueBroadcast();
              return;
          }
        }
    }
    catch (OperationCanceledException) { }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ObjectDisposedException)
    {
      // The keeper reconnected or the session went away: the phone hears it as detached and can open it again.
      if (link.Attached.TryRemove(id, out _)) await PublishAsync(channel, Json(new JsonObject { ["t"] = "detached", ["id"] = id }));
    }
  }

  private bool Working(string id) => lastOutput.TryGetValue(id, out var at) && Environment.TickCount64 - at < 2500;

  private JsonObject Status(SessionRecord session) => new()
  {
    ["t"] = "status", ["id"] = session.Definition.Id, ["status"] = host.ObservedStatus(session) ?? PhoneSessionRows.TerminalStatus(session, Working(session.Definition.Id)),
    ["lastActivityAt"] = Math.Max(session.CreatedAt, LastActivity(session.Definition.Id) ?? 0)
  };
  private long? LastActivity(string id) => lastOutput.TryGetValue(id, out var at) ? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - (Environment.TickCount64 - at) : null;

  private async ValueTask<PhoneApplicationReply> CreateAsync(ApprovedDevice device, Link link, JsonElement message, CancellationToken ct)
  {
    var provider = message.TryGetProperty("provider", out var p) && p.ValueKind == JsonValueKind.String ? p.GetString()! : "shell";
    if (provider is not ("claude" or "codex" or "gemini" or "shell") && !host.TerminalProviders().Any(p => p.Id == provider)) throw new PhoneRefusal("unavailable", "Choose a terminal provider offered by this computer.");
    var folder = message.TryGetProperty("cwd", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString()! : host.Folders(device).FirstOrDefault()
      ?? throw new PhoneRefusal("unavailable", "Choose a folder this computer shares with this phone.");
    if (folder.Length > 1024 || folder.Any(char.IsControl) || !host.MayStartIn(device, folder))
      throw new PhoneRefusal("unauthorized", "This phone cannot start a session in that folder.");
    var account = Optional(message, "account", 200);
    if (account is not null && device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Choosing a login for a new session needs Full control.");
    var session = await host.StartTerminalAsync(provider, folder, account, ct);
    if (Size(message) is { } size) { try { await host.ResizeAsync(session.Definition.Id, size, ct); } catch (IOException) { } }
    QueueBroadcast();
    return Reply(new JsonObject { ["t"] = "created", ["session"] = PhoneSessionRows.Terminal(session, false, observedStatus: host.ObservedStatus(session)) });
  }

  // ---- agent chats -----------------------------------------------------------------------------

  private async ValueTask<PhoneApplicationReply> ChatsAsync(Link link, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    var engine = host.ChatEngine ?? throw new PhoneRefusal("unavailable", "Agent chats are reconnecting on this computer. Try again in a moment.");
    switch (type)
    {
      case "chats.choices": return Reply(Choices(rid ?? "", Optional(message, "cwd", 1024)));
      case "chats.new":
      {
        var provider = Text(message, "provider", 16);
        if (provider is not ("claude" or "codex" or "gemini")) throw new PhoneRefusal("bad-message", "chats.new naming no chat agent");
        var folder = Text(message, "cwd", 1024);
        if (!host.MayStartIn(device, folder)) throw new PhoneRefusal("unauthorized", "This phone cannot start a chat in that folder.");
        var account = Optional(message, "account", 200); var mode = PhoneSessionRows.PermissionMode(Optional(message, "permissionMode", 16), provider);
        if ((account is not null || mode is not null) && device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Choosing a login or permission mode for a new session needs Full control.");
        var chat = await host.StartChatAsync(provider, folder, account, new(Optional(message, "model", 120) ?? "", Optional(message, "effort", 16) ?? ""), mode, ct);
        QueueBroadcast();
        var created = new JsonObject { ["t"] = "created", ["session"] = PhoneSessionRows.Chat(chat) };
        if (rid is not null) created["rid"] = rid;
        return Reply(created);
      }
    }
    var id = Id(message, "id");
    var current = Chat(device, id);
    if (current is null) return Reply(Unknown(id));
    switch (type)
    {
      case "chats.watch": link.WatchedChats[id] = Fingerprint(current); return new([PhoneSessionRows.ChatEvents(current)]);
      case "chats.unwatch": link.WatchedChats.TryRemove(id, out _); return new([]);
      case "chats.older": return new([PhoneSessionRows.ChatEvents(current, Whole(message, "before", 0, 1_000_000))]);
      case "chats.say": case "chats.steer":
      {
        var text = PhoneChatText.Read(message);
        var paths = PhoneUploadedFiles.Paths(message);
        if (text.Trim().Length == 0 && paths.Length == 0) throw new PhoneRefusal("bad-message", "Chat message without text or attachments");
        var clientId = Optional(message, "clientMessageId", 128) ?? Guid.NewGuid().ToString();
        var files = paths.Length == 0 ? [] : await host.AttachmentsAsync(device, paths, ct);
        foreach (var file in files) file.Validate(current.Definition.Provider);
        var media = new List<ChatMedia>();
        void RequireCurrent()
        {
          var latest = trust.RequireCurrent(link.DeviceId, link.Key);
          if (latest is null || latest.Access is not (PhoneAccess.Work or PhoneAccess.Full) || Chat(latest, id) is not { } visible || !host.MayStartIn(latest, visible.Definition.Cwd))
            throw new PhoneRefusal("unauthorized", "This phone no longer has access to send to this chat.");
        }
        RequireCurrent();
        var existing = engine.Get(id).Messages.FirstOrDefault(m => m.ClientId == clientId);
        if (existing is not null)
        {
          if (existing.Text != text || existing.Media.Length != files.Length) throw new PhoneRefusal("bad-message", "That message id already belongs to another message.");
          for (var index = 0; index < files.Length; index++)
          {
            RequireCurrent();
            var prior = existing.Media[index]; var file = files[index];
            var bytes = await engine.ReadImageAsync(id, prior, ct);
            if (prior.Name != (file.Name.Length > 120 ? file.Name[..120] : file.Name) || prior.MimeType != file.MimeType || !bytes.AsSpan().SequenceEqual(file.Data)) throw new PhoneRefusal("bad-message", "That message id already belongs to other attachments.");
          }
          RequireCurrent(); await engine.SendAsync(id, clientId, text, existing.Media, ct); return new([]);
        }
        foreach (var file in files)
        {
          RequireCurrent();
          media.Add(await engine.AddImageAsync(id, file.Name, file.MimeType, file.Data, file.Width, file.Height, ct));
        }
        RequireCurrent();
        await engine.SendAsync(id, clientId, text, media.ToArray(), ct); return new([]);
      }
      case "chats.interrupt": await engine.StopAsync(id, ct); return new([]);
      case "chats.answer":
      {
        if (!message.TryGetProperty("approved", out var approved) || approved.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new PhoneRefusal("bad-message", "chats.answer without a decision");
        await engine.AnswerAsync(id, Text(message, "request", 512), approved.GetBoolean(), ct); return new([]);
      }
      case "chats.options": return Reply(await OptionsAsync(engine, current, ct));
      case "chats.set":
      {
        var model = Optional(message, "model", 120); var effort = Optional(message, "effort", 16);
        var mode = PhoneSessionRows.PermissionMode(Optional(message, "permissionMode", 16), current.Definition.Provider);
        if (mode is not null && device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Changing a chat's permission mode needs Full control.");
        if (model is not null || effort is not null)
          await engine.SetOptionsAsync(id, new(model ?? current.Definition.Options.Model, effort ?? current.Definition.Options.Effort), ct);
        if (mode is { } chosen) await engine.SetPermissionAsync(id, chosen, ct);
        return Reply(await OptionsAsync(engine, engine.Get(id), ct));
      }
      default: throw new PhoneRefusal("bad-message", "unknown message type: " + type);
    }
  }

  private static async ValueTask<JsonObject> OptionsAsync(IChatSessions engine, ChatRecord chat, CancellationToken ct)
  {
    IReadOnlyList<ProviderModel> models = [];
    try
    {
      using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct); limit.CancelAfter(TimeSpan.FromSeconds(4));
      models = await engine.ModelsAsync(chat.Definition.Id, limit.Token);
    }
    catch (Exception ex) when (ex is OperationCanceledException or IOException or InvalidOperationException or NotSupportedException) { }
    var provider = chat.Definition.Provider;
    var efforts = models.FirstOrDefault(m => m.Id == chat.Definition.Options.Model)?.Efforts ?? (provider == "gemini" ? Array.Empty<string>() : new[] { "low", "medium", "high" });
    return new JsonObject
    {
      ["t"] = "chats.options", ["id"] = chat.Definition.Id,
      ["options"] = new JsonObject
      {
        ["documents"] = provider == "claude",
        ["permissionMode"] = PhoneSessionRows.PermissionWord(chat.Definition.PermissionMode),
        ["model"] = chat.Definition.Options.Model.Length > 0 ? chat.Definition.Options.Model : models.FirstOrDefault(m => m.IsDefault)?.Id,
        ["effort"] = chat.Definition.Options.Effort.Length > 0 ? chat.Definition.Options.Effort : null,
        ["models"] = new JsonArray(models.Take(64).Select(m => (JsonNode)new JsonObject { ["id"] = m.Id, ["name"] = m.Name, ["provider"] = Name(provider) }).ToArray()),
        ["efforts"] = new JsonArray(efforts.Take(16).Select(e => (JsonNode?)e).ToArray())
      }
    };
  }

  private JsonObject Choices(string rid, string? folder)
  {
    var accounts = host.Accounts();
    var providers = new JsonArray();
    foreach (var provider in new[] { "claude", "codex", "gemini" })
    {
      var preferred = folder is null ? null : host.PreferredAccount(provider, folder);
      var row = new JsonObject { ["id"] = provider, ["name"] = Name(provider), ["chat"] = true, ["models"] = new JsonArray(),
        ["efforts"] = provider == "gemini" ? new JsonArray() : new JsonArray("low", "medium", "high") };
      if (preferred is not null) row["defaultAccount"] = preferred.Id;
      providers.Add(row);
    }
    providers.Add(new JsonObject { ["id"] = "shell", ["name"] = "PowerShell", ["chat"] = false, ["models"] = new JsonArray(), ["efforts"] = new JsonArray() });
    foreach (var custom in host.TerminalProviders().Take(32)) providers.Add(new JsonObject { ["id"] = custom.Id, ["name"] = custom.Name, ["chat"] = false, ["models"] = new JsonArray(), ["efforts"] = new JsonArray() });
    return new JsonObject
    {
      ["t"] = "chats.choices", ["rid"] = rid, ["providers"] = providers,
      ["accounts"] = new JsonArray(accounts.Where(a => a.SignedIn).Take(64).Select(a => (JsonNode)new JsonObject { ["id"] = a.Id, ["name"] = a.Name, ["provider"] = a.Provider }).ToArray()),
      ["agents"] = new JsonArray(), ["defaultProvider"] = "claude", ["openAs"] = "chat"
    };
  }

  private static string Name(string provider) => provider switch { "claude" => "Claude", "codex" => "Codex", "gemini" => "Gemini", "shell" => "PowerShell", _ => provider };
  private static string Fingerprint(ChatRecord chat) => chat.Events.Length + ":" + (chat.Events.LastOrDefault()?.Sequence ?? 0) + ":" + chat.Busy + ":" + chat.Stopping + ":" + chat.Messages.Length + ":" + chat.Ended + ":" + chat.Problem;

  // ---- rows and pushes -------------------------------------------------------------------------

  private SessionRecord? Terminal(ApprovedDevice device, string id) => host.Terminals().FirstOrDefault(s => s.Definition.Id == id && host.Visible(device, s));
  private ChatRecord? Chat(ApprovedDevice device, string id) => host.Chats().FirstOrDefault(c => c.Definition.Id == id && host.Visible(device, c));

  private JsonArray Rows(ApprovedDevice device) => device.Access == PhoneAccess.Hoot ? new JsonArray() : PhoneSessionRows.Bounded(
    host.Terminals().Where(s => host.Visible(device, s) && s.Definition.Purpose is null).Select(s => PhoneSessionRows.Terminal(s, Working(s.Definition.Id), LastActivity(s.Definition.Id), host.ObservedStatus(s)))
      // An ended chat is history on this PC (its archive), not a session to open.
      .Concat(host.Chats().Where(c => !c.Ended && host.Visible(device, c)).Select(PhoneSessionRows.Chat)));

  private JsonObject Sessions(ApprovedDevice device, Link link)
  {
    var rows = Rows(device); link.LastSessions = Shape(rows);
    return new JsonObject { ["t"] = "sessions", ["sessions"] = rows };
  }

  // What a sessions push is for: rows, titles and states; a moving last-activity time alone is not news.
  private static string Shape(JsonArray rows) => string.Join("|", rows.Select(r => r is JsonObject o
    ? string.Join(",", o.Where(p => p.Key != "lastActivityAt").Select(p => p.Key + "=" + p.Value?.ToJsonString())) : ""));

  private void Changed() => QueueBroadcast();
  private void QueueBroadcast()
  {
    if (Interlocked.Exchange(ref broadcastQueued, 1) == 1) return;
    _ = Task.Run(async () =>
    {
      await Task.Delay(250);
      Interlocked.Exchange(ref broadcastQueued, 0);
      try { await BroadcastAsync(); }
      catch (Exception ex) when (ex is not OperationCanceledException) { System.Diagnostics.Trace.WriteLine("Phone sessions push failed: " + ex.Message); }
    });
  }

  private async Task BroadcastAsync()
  {
      foreach (var (channel, link) in links)
      {
        ApprovedDevice device;
        try { device = trust.RequireCurrent(link.DeviceId, link.Key); } catch (ProtocolException) { continue; }
        var rows = Rows(device); var text = Shape(rows);
        if (text != link.LastSessions) { link.LastSessions = text; await PublishAsync(channel, Json(new JsonObject { ["t"] = "sessions", ["sessions"] = rows })); }
        foreach (var (chatId, seen) in link.WatchedChats)
        {
          var chat = Chat(device, chatId);
          if (chat is null) { link.WatchedChats.TryRemove(chatId, out _); continue; }
          var now = Fingerprint(chat);
          if (now == seen) continue;
          link.WatchedChats[chatId] = now;
          await PublishAsync(channel, PhoneSessionRows.ChatEvents(chat));
        }
      }
  }

  private ApprovedDevice? DeviceFor(string channel)
  {
    if (!links.TryGetValue(channel, out var link)) return null;
    try { return trust.RequireCurrent(link.DeviceId, link.Key); } catch (ProtocolException) { return null; }
  }

  private async ValueTask PublishAsync(string channel, byte[] message)
  {
    var publish = Volatile.Read(ref publisher);
    if (publish is null || !links.ContainsKey(channel)) return;
    try { await publish(channel, message, CancellationToken.None); }
    catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException or ProtocolException or System.Net.WebSockets.WebSocketException) { }
  }

  public async ValueTask DisconnectedAsync(string channel)
  {
    if (links.TryRemove(channel, out var link))
    {
      link.Life.Cancel();
      foreach (var stop in link.Attached.Values) stop.Dispose();
      link.Life.Dispose();
    }
    activity?.Unwatch(channel);
    if (screens is not null) await screens.ClosedAsync(channel);
    if (workspace is not null) await workspace.DisconnectedAsync(channel);
    await next.DisconnectedAsync(channel);
  }

  public void Dispose()
  {
    if (disposed) return;
    disposed = true; host.Changed -= Changed; trust.Changed -= Changed;
    foreach (var link in links.Values) link.Life.Cancel();
    links.Clear(); activity?.Dispose(); screens?.Dispose();
    (workspace as IDisposable)?.Dispose();
    (next as IDisposable)?.Dispose();
  }

  // ---- helpers ---------------------------------------------------------------------------------

  private static PhoneApplicationReply Reply(JsonObject message) => new([Json(message)]);
  private static byte[] Json(JsonObject message) => JsonSerializer.SerializeToUtf8Bytes(message);
  private static JsonObject Error(string code, string message, string? rid = null)
  {
    var error = new JsonObject { ["t"] = "error", ["code"] = code, ["message"] = message };
    if (rid is not null) error["rid"] = rid;
    return error;
  }
  private static JsonObject Unknown(string id) => Error("unknown-session", "That session is not on this computer any more.");
  private static string Plain(string message) => message.Length is > 0 and <= 400 ? message : "That did not work on this computer.";

  private static JsonElement Parse(ReadOnlyMemory<byte> bytes)
  {
    if (bytes.Length > PhoneWire.MaximumMessageBytes) throw new ProtocolException("The phone message is too large.");
    try
    {
      _ = new UTF8Encoding(false, true).GetString(bytes.Span);
      using var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
      if (doc.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException();
      return doc.RootElement.Clone();
    }
    catch (Exception ex) when (ex is JsonException or DecoderFallbackException) { throw new ProtocolException("The phone message is unusable."); }
  }
  internal static string Id(JsonElement message, string key)
  {
    var value = Text(message, key, 128);
    if (!System.Text.RegularExpressions.Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9_:.-]{0,127}$")) throw new PhoneRefusal("bad-message", "That id is not usable.");
    return value;
  }
  internal static string Text(JsonElement message, string key, int limit, bool empty = false, bool controls = false)
  {
    if (!message.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String) throw new PhoneRefusal("bad-message", "The phone message is missing " + key + ".");
    var text = value.GetString()!;
    if ((!empty && text.Length == 0) || Encoding.UTF8.GetByteCount(text) > limit || (!controls && text.Any(char.IsControl))) throw new PhoneRefusal("bad-message", "The phone message has an unusable " + key + ".");
    return text;
  }
  internal static string? Optional(JsonElement message, string key, int limit) =>
    message.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } ? Text(message, key, limit) : null;
  internal static int Whole(JsonElement message, string key, int min, int max)
  {
    if (!message.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var number) || number != Math.Floor(number) || number < min || number > max)
      throw new PhoneRefusal("bad-message", "The phone message has an unusable " + key + ".");
    return (int)number;
  }
  private static TerminalSize? Size(JsonElement message)
  {
    if (!message.TryGetProperty("cols", out _) && !message.TryGetProperty("rows", out _)) return null;
    var size = new TerminalSize(Whole(message, "cols", 20, 500), Whole(message, "rows", 5, 200)); size.Validate(); return size;
  }
}

// A refusal the phone hears as an error frame, with the connection kept.
public sealed class PhoneRefusal(string code, string message) : Exception(message)
{
  public string Code { get; } = code;
}
