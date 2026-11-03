using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Remote;

public sealed record PhonePushRegistration(string DeviceId, string Name, string Platform, string Mailbox, string Key,
  string? Apns, string? Fcm, bool Sandbox, bool NeedsYou, bool Finished, bool Hoot, bool Preview);
public sealed record PhonePushState(PhonePushRegistration[] Registrations);
public sealed record PhonePushNotice(string Kind, string Session, string Agent, string Title, string Folder, string? Preview = null);
public sealed record PhonePushRelay(string HostId, byte[] Secret, Uri Base);

// Shared notification owner: phone messages and app events use this one store.
public sealed class PhonePushFeatures(IStateStore<PhonePushState> store,
  Func<string, PhonePushNotice, bool> mayHear, Func<PhonePushRelay?> relay,
  Func<Uri, IReadOnlyDictionary<string, string>, byte[]?, CancellationToken, ValueTask<(int Status, byte[] Body)>> send,
  string hostName) : IPhoneHostWorkspace
{
  private readonly object gate = new();
  private PhonePushState state = store.Load() ?? new([]);
  private readonly ConcurrentDictionary<string, string> onScreen = new();
  private bool apns, fcm;
  public IReadOnlyList<string> Capabilities => ["push"];
  public bool Handles(string type) => type is "push.register" or "push.presence" or "push.forget";
  public bool Permits(PhoneAccess access, string type) => true;
  public ValueTask DisconnectedAsync(string channel) { onScreen.TryRemove(channel, out _); return ValueTask.CompletedTask; }
  public void Forget(string deviceId)
  {
    lock (gate) { var next = new PhonePushState(state.Registrations.Where(r => r.DeviceId != deviceId).ToArray()); store.Save(next); state = next; }
    foreach (var row in onScreen.Where(p => p.Value == deviceId)) onScreen.TryRemove(row.Key, out _);
  }
  public string[] DeviceIds() { lock (gate) return state.Registrations.Select(r => r.DeviceId).ToArray(); }
  public IReadOnlyList<object> Rows() { lock (gate) return state.Registrations.Select(r => (object)new { deviceId = r.DeviceId, name = r.Name, platform = r.Platform,
    delivery = r.Apns is not null && apns || r.Fcm is not null && fcm ? "instant" : "mailbox", onScreen = onScreen.Values.Contains(r.DeviceId), needsYou = r.NeedsYou, finished = r.Finished, hoot = r.Hoot, preview = r.Preview }).ToArray(); }
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (type == "push.forget") { Forget(device.Id); return [Frame("off")]; }
    var visible = Flag(message, "onScreen", false);
    if (visible) onScreen[channel] = device.Id; else onScreen.TryRemove(channel, out _);
    if (type == "push.presence") return [];
    var key = Text(message, "key", 64)!;
    try { if (Decode(key).Length != 32) throw new FormatException(); } catch (FormatException) { throw new PhoneRefusal("bad-message", "Choose a valid alert key."); }
    var mailbox = Text(message, "mailbox", 128)!;
    if (!mailbox.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) throw new PhoneRefusal("bad-message", "Choose a valid alert mailbox.");
    var row = new PhonePushRegistration(device.Id, Text(message, "name", 64, true) ?? device.Name, Text(message, "platform", 16)!, mailbox, key,
      Text(message, "apns", 256, true), Text(message, "fcm", 4096, true), Flag(message, "sandbox", false), Flag(message, "needsYou", true),
      Flag(message, "finished", true), Flag(message, "hoot", true), Flag(message, "preview", false));
    lock (gate)
    {
      var next = new PhonePushState(state.Registrations.Where(r => r.DeviceId != device.Id).Append(row).TakeLast(64).ToArray());
      store.Save(next); state = next;
    }
    await RefreshStatusAsync(ct);
    return [Frame(row.Apns is not null && apns || row.Fcm is not null && fcm ? "instant" : "mailbox")];
  }
  private DateTimeOffset statusAt;
  private async ValueTask RefreshStatusAsync(CancellationToken ct)
  {
    if (DateTimeOffset.UtcNow - statusAt < TimeSpan.FromMinutes(10) || relay() is not { } endpoint) return;
    try
    {
      var answer = await send(new Uri(endpoint.Base, "v1/push/status"), new Dictionary<string, string>(), null, ct);
      if (answer.Status != 200 || answer.Body.Length > 4096) return;
      using var json = JsonDocument.Parse(answer.Body);
      apns = json.RootElement.TryGetProperty("apns", out var a) && a.ValueKind == JsonValueKind.True;
      fcm = json.RootElement.TryGetProperty("fcm", out var f) && f.ValueKind == JsonValueKind.True; statusAt = DateTimeOffset.UtcNow;
    }
    catch (Exception e) when (e is IOException or HttpRequestException or JsonException) { }
    finally { CryptographicOperations.ZeroMemory(endpoint.Secret); }
  }
  private JsonObject Frame(string delivery) => new() { ["t"] = "push.state", ["delivery"] = delivery, ["apns"] = apns, ["fcm"] = fcm };
  public async ValueTask<int> NotifyAsync(PhonePushNotice notice, CancellationToken ct = default)
  {
    if (notice.Kind is not ("needs-you" or "finished" or "hoot")) throw new ArgumentException("Choose an alert kind.");
    var target = relay(); if (target is null) return 0;
    try
    {
    PhonePushRegistration[] rows; lock (gate) rows = state.Registrations.ToArray();
    var sent = 0;
    foreach (var row in rows)
    {
      ct.ThrowIfCancellationRequested();
      if (onScreen.Values.Contains(row.DeviceId) || !mayHear(row.DeviceId, notice) || !(notice.Kind == "needs-you" ? row.NeedsYou : notice.Kind == "finished" ? row.Finished : row.Hoot)) continue;
      var preview = row.Preview && notice.Preview is not null ? Redact(notice.Preview) : null;
      var payload = JsonSerializer.SerializeToUtf8Bytes(new { v = 1, k = notice.Kind, agent = notice.Agent, title = Cut(notice.Title, 120), host = target.HostId,
        session = notice.Session, mac = Cut(hostName, 64), at = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), preview });
      var key = Decode(row.Key); var nonce = RandomNumberGenerator.GetBytes(12); var cipher = new byte[payload.Length]; var tag = new byte[16];
      try { using var aes = new AesGcm(key, 16); aes.Encrypt(nonce, payload, cipher, tag); } finally { CryptographicOperations.ZeroMemory(key); }
      var combined = new byte[nonce.Length + cipher.Length + tag.Length]; nonce.CopyTo(combined, 0); cipher.CopyTo(combined, nonce.Length); tag.CopyTo(combined, nonce.Length + cipher.Length);
      var message = new JsonObject { ["mailbox"] = row.Mailbox, ["sealed"] = Encode(combined), ["kind"] = notice.Kind,
        ["collapse"] = Cut(Regex.Replace(notice.Session, "[^A-Za-z0-9_.:-]", ""), 48) + (notice.Kind == "finished" ? ":f" : ":n"),
        ["route"] = new JsonObject { ["host"] = target.HostId, ["chat"] = notice.Session } };
      if (row.Apns is not null) { message["apns"] = new JsonObject { ["token"] = row.Apns, ["sandbox"] = row.Sandbox }; message["alert"] = new JsonObject { ["title"] = notice.Kind == "hoot" ? "Hoot replied" : notice.Agent + (notice.Kind == "finished" ? " finished" : " needs you"), ["body"] = preview ?? "Open the app to see it." }; }
      if (row.Fcm is not null) message["fcm"] = row.Fcm;
      // Check again after sealing: revocation during preparation never sends.
      if (!mayHear(row.DeviceId, notice) || onScreen.Values.Contains(row.DeviceId)) continue;
      var reply = await send(new Uri(target.Base, "v1/push"), new Dictionary<string, string> { ["x-deck-host-secret"] = Encode(target.Secret), ["content-type"] = "application/json" }, JsonSerializer.SerializeToUtf8Bytes(new JsonObject { ["messages"] = new JsonArray(message) }), ct);
      if (reply.Status != 200) continue;
      sent++;
      if (reply.Body.Length <= 65536)
      {
        using var json = JsonDocument.Parse(reply.Body); apns = json.RootElement.TryGetProperty("apns", out var a) && a.ValueKind == JsonValueKind.True; fcm = json.RootElement.TryGetProperty("fcm", out var f) && f.ValueKind == JsonValueKind.True;
        if (json.RootElement.TryGetProperty("results", out var results) && results.ValueKind == JsonValueKind.Array && results.GetArrayLength() > 0)
        {
          var result = results[0];
          var dropApns = result.TryGetProperty("apns", out var ar) && ar.GetString() == "gone";
          var dropFcm = result.TryGetProperty("fcm", out var fr) && fr.GetString() == "gone";
          if (dropApns || dropFcm) lock (gate)
          {
            var next = new PhonePushState(state.Registrations.Select(r => r.DeviceId == row.DeviceId && r.Key == row.Key ? r with { Apns = dropApns && r.Apns == row.Apns ? null : r.Apns, Fcm = dropFcm && r.Fcm == row.Fcm ? null : r.Fcm } : r).ToArray());
            store.Save(next); state = next;
          }
        }
      }
    }
    return sent;
    }
    finally { CryptographicOperations.ZeroMemory(target.Secret); }
  }
  public static string Redact(string value)
  {
    value = Regex.Replace(value, @"\s+", " ");
    value = Regex.Replace(value, @"(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+|[A-Za-z0-9+/_=-]{32,}", "•••");
    return Cut(value.Trim(), 180);
  }
  private static string Cut(string s, int max) => s[..Math.Min(max, s.Length)];
  private static byte[] Decode(string s) => Convert.FromBase64String(s.Replace('-', '+').Replace('_', '/').PadRight((s.Length + 3) / 4 * 4, '='));
  private static string Encode(byte[] b) => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');
  private static string? Text(JsonElement m, string k, int max, bool optional = false) => !m.TryGetProperty(k, out var v) && optional ? null : v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s && s.Length <= max && !s.Any(char.IsControl) ? s : throw new PhoneRefusal("bad-message", "Invalid " + k + ".");
  private static bool Flag(JsonElement m, string k, bool fallback) => !m.TryGetProperty(k, out var v) ? fallback : v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : throw new PhoneRefusal("bad-message", "Invalid " + k + ".");
}
