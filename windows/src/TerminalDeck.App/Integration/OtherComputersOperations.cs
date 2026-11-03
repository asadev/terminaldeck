using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.App.Integration;

public sealed record ComputerServices(JsonElement[] Sessions, JsonElement Hoot, JsonElement[] Ports, string[] Folders);
public sealed partial class OtherComputersService
{
  private readonly ConcurrentDictionary<string, byte> retrying = new();
  private readonly ConcurrentDictionary<string, byte> wanted = new();
  private readonly CancellationTokenSource lifetime = new();
  private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> creating = new();
  private readonly ConcurrentDictionary<string, ComputerServices> services = new();
  private readonly ConcurrentDictionary<(string Computer, string Request), (string Field, string[] Replies, TaskCompletionSource<JsonElement> Completion)> pending = new();
  private readonly ConcurrentDictionary<(string Computer, string Session), (int Cols, int Rows)> attached = new();
  public ComputerServices Services(string id) => services.GetValueOrDefault(id) ?? new([], JsonSerializer.SerializeToElement(new { granted = false }), [], []);
  private void AcceptSnapshot(string id, JsonElement frame)
  {
    var old = Services(id); var tag = Text(frame, "t", "");
    if (tag == "created" && frame.TryGetProperty("session", out var created) && Text(created, "id", "").Length > 0 && creating.TryGetValue(id, out var waiting)) waiting.TrySetResult(created.Clone());
    if (tag == "error" && creating.TryGetValue(id, out var refused) && !frame.TryGetProperty("rid", out _)) refused.TrySetException(new ProtocolException(Text(frame, "message", "The session could not be started.")));
    JsonElement[] Rows(string field) => frame.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().Take(128).Select(v => v.Clone()).ToArray() : [];
    var next = tag switch
    {
      "welcome" => new ComputerServices(Rows("sessions").Where(s => Text(s, "id", "").Length is > 0 and <= 128).ToArray(), frame.TryGetProperty("hoot", out var h) ? h.Clone() : old.Hoot, [], Rows("folders").Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!).ToArray()),
      "sessions" => old with { Sessions = Rows("sessions").Where(s => Text(s, "id", "").Length is > 0 and <= 128).ToArray() },
      "created" when frame.TryGetProperty("session", out var row) => old with { Sessions = old.Sessions.Where(s => Text(s, "id", "") != Text(row, "id", "")).Append(row.Clone()).ToArray() },
      "closed" => old with { Sessions = old.Sessions.Where(s => Text(s, "id", "") != Text(frame, "id", "")).ToArray() },
      "ports" => old with { Ports = Rows("ports") },
      "hoot.state" or "hoot.chat" => old with { Hoot = HootSnapshot(old.Hoot, tag, frame) },
      "status" or "exit" => old with { Sessions = old.Sessions.Select(s => UpdateSession(s, frame, tag)).ToArray() },
      "hoot.grant" when frame.TryGetProperty("link", out var link) => old with { Hoot = link.Clone() },
      _ => old
    };
    services[id] = next;
    if (next != old) Changed?.Invoke();
  }
  private static JsonElement HootSnapshot(JsonElement grant, string tag, JsonElement frame)
  {
    var data = grant.ValueKind == JsonValueKind.Object ? JsonNode.Parse(grant.GetRawText())!.AsObject() : new JsonObject();
    data[tag == "hoot.state" ? "state" : "chat"] = JsonNode.Parse(frame.GetRawText());
    return JsonSerializer.SerializeToElement(data);
  }
  private static JsonElement UpdateSession(JsonElement session, JsonElement frame, string tag)
  {
    if (Text(session, "id", "") != Text(frame, "id", "")) return session;
    var row = JsonNode.Parse(session.GetRawText())!.AsObject();
    row["status"] = tag == "exit" ? "exited" : Text(frame, "status", "unknown");
    if (frame.TryGetProperty("exitCode", out var code)) row["exitCode"] = JsonNode.Parse(code.GetRawText());
    return JsonSerializer.SerializeToElement(row);
  }
  private void CompleteRequest(string id, JsonElement frame)
  {
    var tag = Text(frame, "t", "");
    foreach (var entry in pending.Where(p => p.Key.Computer == id))
    {
      if (Text(frame, entry.Value.Field, "") != entry.Key.Request) continue;
      if (tag == "error" || tag is "upload.failed" or "tunnel.closed") entry.Value.Completion.TrySetException(new ProtocolException(Text(frame, "message", "The other computer refused this request.")));
      else if (entry.Value.Replies.Contains(tag)) entry.Value.Completion.TrySetResult(frame.Clone());
    }
  }
  private void FailRequests(string id)
  {
    foreach (var entry in pending.Where(p => p.Key.Computer == id)) entry.Value.Completion.TrySetException(new IOException("The computer disconnected. The request outcome is unknown."));
    services.TryRemove(id, out _);
    if (creating.TryGetValue(id, out var start)) start.TrySetException(new IOException("The connection ended before session creation was confirmed."));
  }
  public async Task<JsonElement> RequestAsync(string id, string capability, string type, JsonObject fields, string[] replies, CancellationToken ct = default, string correlation = "rid", string? requestId = null)
  {
    RequireCapability(id, capability);
    if (fields.ContainsKey("t") || fields.ContainsKey(correlation)) throw new ArgumentException("Request fields cannot replace the protocol tag or correlation.");
    if (pending.Count >= 64) throw new InvalidOperationException("Too many computer requests are waiting.");
    var rid = requestId ?? Guid.NewGuid().ToString("N"); var done = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
    if (!pending.TryAdd((id, rid), (correlation, replies, done))) throw new InvalidOperationException("That request is already running.");
    try
    {
      fields["t"] = type; fields[correlation] = rid;
      await SendAsync(id, fields, ct);
      return await done.Task.WaitAsync(TimeSpan.FromSeconds(45), ct);
    }
    finally { pending.TryRemove((id, rid), out _); }
  }
  public void RequireCapability(string id, string capability)
  {
    var row = List().FirstOrDefault(c => c.Id == id);
    if (row?.State != "Online" || !row.Capabilities.Contains(capability)) throw new InvalidOperationException("This computer does not currently grant " + capability + ".");
  }
  public async Task<JsonElement> CreateSessionAsync(string id, JsonObject fields, CancellationToken ct = default)
  {
    RequireCapability(id, "create");
    var done = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
    if (!creating.TryAdd(id, done)) throw new InvalidOperationException("Another session is already starting on this computer.");
    try
    {
      var message = new JsonObject { ["t"] = "create" };
      foreach (var pair in fields)
      {
        if (pair.Key is not ("cwd" or "provider" or "agent" or "account" or "model" or "effort" or "permissionMode" or "chat")) throw new ArgumentException("That is not a supported new-session choice.");
        message[pair.Key] = pair.Value?.DeepClone();
      }
      await SendAsync(id, message, ct);
      return await done.Task.WaitAsync(TimeSpan.FromSeconds(45), ct);
    }
    finally { creating.TryRemove(id, out _); }
  }
  public async Task<JsonElement> OperateAsync(string id, string action, JsonObject fields, CancellationToken ct = default)
  {
    var operation = ComputerOperations.Validate(action, fields);
    var session = fields["id"]?.GetValue<string>();
    var want = fields["want"]?.GetValue<string>();
    var reply = await RequestAsync(id, operation.Capability, operation.Tag, fields, [operation.Reply], ct);
    if (session is not null && Text(reply, "id", "") != session) throw new ProtocolException("The computer answered for a different session.");
    if (want is not null && Text(reply, "want", "") != want) throw new ProtocolException("The computer answered a different usage question.");
    return reply;
  }
  public async Task AttachAsync(string id, string session, int cols, int rows, CancellationToken ct = default)
  {
    if (!Services(id).Sessions.Any(s => Text(s, "id", "") == session)) throw new InvalidOperationException("Choose a session currently shared by this computer.");
    cols = Math.Clamp(cols, 20, 500); rows = Math.Clamp(rows, 5, 200);
    attached[(id, session)] = (cols, rows);
    await SendAsync(id, new { t = "attach", id = session, cols, rows }, ct);
  }
  public async Task DetachAsync(string id, string session)
  {
    attached.TryRemove((id, session), out _);
    await SendAsync(id, new { t = "detach", id = session });
  }
  public async Task HootAsync(string id, string type, string? text = null, CancellationToken ct = default)
  {
    RequireCapability(id, "hoot");
    var grant = Services(id).Hoot;
    if (!grant.TryGetProperty("granted", out var allowed) || allowed.ValueKind != JsonValueKind.True) throw new InvalidOperationException("Grant Hoot access on the other computer first.");
    if (!grant.TryGetProperty("open", out var open) || open.ValueKind != JsonValueKind.True) await SendAsync(id, new { t = "hoot.hello" }, ct);
    await SendAsync(id, text is null ? new JsonObject { ["t"] = type } : new JsonObject { ["t"] = type, ["text"] = text }, ct);
  }
  private async Task RestoreWatchesAsync(string id, CancellationToken ct)
  {
    foreach (var pair in attached.Where(p => p.Key.Computer == id))
      if (Services(id).Sessions.Any(s => Text(s, "id", "") == pair.Key.Session))
        try { await AttachAsync(id, pair.Key.Session, pair.Value.Cols, pair.Value.Rows, ct); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
  public void Nudge()
  {
    foreach (var id in wanted.Keys) if (!List().Any(c => c.Id == id && c.State is "Online" or "Connecting")) ScheduleReconnect(id);
  }
  private void NetworkChanged(object? sender, System.Net.NetworkInformation.NetworkAvailabilityEventArgs e)
  {
    if (e.IsAvailable) foreach (var id in wanted.Keys.ToArray()) ScheduleReconnect(id);
  }
  private void ScheduleReconnect(string id)
  {
    if (List().Any(c => c.Id == id && c.State == "Online")) return;
    FailRequests(id);
    if (lifetime.IsCancellationRequested || !wanted.ContainsKey(id) || !retrying.TryAdd(id, 0)) return;
    _ = RetryAsync();
    async Task RetryAsync()
    {
      try
      {
        var attempt = 0;
        while (wanted.ContainsKey(id) && !lifetime.IsCancellationRequested)
        {
          await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, Math.Min(attempt++, 5)))), lifetime.Token);
          try { await ConnectAsync(id, lifetime.Token); return; }
          catch (Exception ex) when (ex is not OutOfMemoryException && !lifetime.IsCancellationRequested) { }
        }
      }
      catch (OperationCanceledException) { }
      finally { retrying.TryRemove(id, out _); }
    }
  }
}
