using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Receiver;

public sealed partial class ReceiverSourceService : IDisposable
{
  private readonly IReceiver receiver;
  private readonly IStateStore<ReceiverSourceSettingsState> store;
  private readonly ISecretStore secrets;
  private readonly string credentialPrefix;
  private readonly ICodeProcessRunner? process;
  private readonly TimeProvider? clock;
  private readonly Func<string, bool>? projectExists;
  private string sourceIdentity;
  public ReceiverSourceService(IReceiver receiver, IStateStore<ReceiverSourceSettingsState> store, ISecretStore secrets, string credentialPrefix, ICodeProcessRunner? process = null, TimeProvider? clock = null, Func<string, bool>? projectExists = null)
  {
    this.receiver = receiver; this.store = store; this.secrets = secrets; this.credentialPrefix = credentialPrefix; this.process = process; this.clock = clock; this.projectExists = projectExists;
    sourceIdentity = JsonSerializer.Serialize(receiver.Sources()); receiver.Changed += BaseSourcesChanged;
  }
  private void BaseSourcesChanged()
  {
    var current = receiver.Sources(); var next = JsonSerializer.Serialize(current);
    lock (gate)
    {
      if (next == sourceIdentity) return; sourceIdentity = next;
      var state = State(); var removed = state.Sources.Where(s => !current.Any(c => c.Id == s.SourceId)).ToArray();
      if (removed.Length > 0) store.Save(state with { Sources = state.Sources.Except(removed).ToArray(), PendingCredentialDeletes = (state.PendingCredentialDeletes ?? []).Concat(removed.SelectMany(s => new[] { s.SecretReference, s.ReplySecretReference }).OfType<string>()).Distinct().ToArray() });
    }
    Changed?.Invoke(); _ = CleanupCredentialsSafelyAsync();
  }
  public void Dispose() => receiver.Changed -= BaseSourcesChanged;
  public string InstanceId { get; } = Guid.NewGuid().ToString("N");
  private readonly object gate = new();
  private readonly SemaphoreSlim replyGate = new(1, 1);
  private TimeProvider Time => clock ?? TimeProvider.System;
  public event Action? Changed;
  private ReceiverSourceSettingsState State() => store.Load() ?? new([], [], []);
  public ReceiverSourcePreset[] Presets() { lock (gate) return ReceiverSourcePresets.BuiltIns.Concat(State().Presets).Select(Clone).ToArray(); }
  private static T Clone<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.SerializeToUtf8Bytes(value))!;
  public ReceiverSourceConfiguration Read(string id)
  {
    _ = Source(id); lock (gate) return Clone(State().Sources.FirstOrDefault(s => s.SourceId == id) ?? new(id, "webhook", new(), new()));
  }
  public string Address(string id)
  {
    _ = Source(id); var builder = new UriBuilder(TerminalDeck.Core.Remote.RelayEndpoint.Default) { Scheme = "https", Path = "/in/" + Uri.EscapeDataString(id), Port = -1 }; return builder.Uri.AbsoluteUri;
  }
  public ReceiverDraft NormalizeInternal(ReceiverDraft draft)
  {
    if (Source(draft.SourceId).Kind == IntakeKind.Webhook) return draft;
    ReceiverSourceConfiguration? config; lock (gate) config = State().Sources.FirstOrDefault(s => s.SourceId == draft.SourceId);
    if (config is null) return draft;
    var original = draft.Payload; if (original is { ValueKind: JsonValueKind.Object } envelope && envelope.TryGetProperty("receiverNormalized", out var marker) && marker.ValueKind == JsonValueKind.True && envelope.TryGetProperty("payload", out var unwrapped)) original = unwrapped;
    var body = original is { } payload ? Encoding.UTF8.GetBytes(payload.GetRawText()) : JsonSerializer.SerializeToUtf8Bytes(new { title = draft.Title, text = draft.Text, url = draft.Url });
    var mapped = ReceiverPayloadMapper.Map(new(draft.SourceId, new Dictionary<string, string>(), body), config.Mapping);
    if (mapped.Length != 1) throw new ArgumentException("Internal source mappings must produce one event.");
    return draft with { Title = string.IsNullOrWhiteSpace(mapped[0].Title) ? draft.Title : mapped[0].Title, Text = mapped[0].Text, Payload = mapped[0].Payload, Ignore = mapped[0].Ignored };
  }
  public ReceiverSource Source(string id) => receiver.Sources().SingleOrDefault(s => s.Id == id) ?? throw new ArgumentException("Choose an existing Receiver source.");
  public ReceiverSource Create(string name, string project, string preset)
  {
    if (projectExists?.Invoke(project) == false) throw new ArgumentException("Choose an existing project for this source.");
    var template = Presets().SingleOrDefault(p => p.Id == preset) ?? throw new ArgumentException("Choose a Receiver source preset.");
    const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; var random = RandomNumberGenerator.GetBytes(26); var id = new string(random.Select(b => alphabet[b & 31]).ToArray());
    var source = new ReceiverSource(id, name, IntakeKind.Webhook, project); receiver.SaveSource(source); Save(new(id, template.Id, template.Proof, template.Mapping, template.Reply)); return source;
  }
  public async Task<ReceiverSource> CreateAsync(string name, string project, string preset, CancellationToken ct = default)
  {
    var source = Create(name, project, preset); if (Read(source.Id).Proof.Scheme != "none") await GenerateCredentialAsync(source.Id, ct); return source;
  }
  public Task<string> ReadCredentialForClipboardAsync(string id, CancellationToken ct = default) => SecretAsync(Read(id).SecretReference, ct);
  public void Save(ReceiverSourceConfiguration configuration)
  {
    _ = Source(configuration.SourceId); Validate(configuration);
    lock (gate)
    {
      var state = State(); var old = state.Sources.SingleOrDefault(s => s.SourceId == configuration.SourceId);
      configuration = Clone(configuration with { SecretReference = old?.SecretReference, ReplySecretReference = old?.ReplySecretReference });
      store.Save(state with { Sources = state.Sources.Where(s => s.SourceId != configuration.SourceId).Append(configuration).ToArray() });
    }
    Changed?.Invoke();
  }
  public void SavePreset(string source, string name)
  {
    ReceiverStore.Check(name, 120); var config = Read(source);
    lock (gate)
    {
      var state = State(); if (state.Presets.Length >= 64) throw new IOException("At most 64 custom Receiver presets can be saved.");
      var preset = new ReceiverSourcePreset(Guid.NewGuid().ToString("N"), name, config.Proof, config.Mapping, config.Reply, false); store.Save(state with { Presets = [.. state.Presets, Clone(preset)] });
    }
    Changed?.Invoke();
  }
  public ReceiverSourceConfiguration Learn(string source)
  {
    var config = Read(source); var item = receiver.Items(source, limit: 1).FirstOrDefault() ?? throw new InvalidOperationException("Receive an event before learning its field paths.");
    var payload = item.Payload; if (payload is { ValueKind: JsonValueKind.Object } normalized && normalized.TryGetProperty("receiverNormalized", out var marker) && marker.ValueKind == JsonValueKind.True && normalized.TryGetProperty("payload", out var original)) payload = original;
    var paths = ReceiverConditions.Paths(new(source, item.Title, item.Text) { Payload = payload });
    string Template(string fallback, params string[] names) { var path = paths.FirstOrDefault(p => names.Any(n => p.Equals(n, StringComparison.OrdinalIgnoreCase) || p.EndsWith("." + n, StringComparison.OrdinalIgnoreCase))); return path is null ? fallback : "{{" + path + "}}"; }
    return config with { Mapping = config.Mapping with { Title = Template(config.Mapping.Title, "title", "subject", "summary", "name"), Text = Template(config.Mapping.Text, "text", "message", "description", "body"), Time = Template(config.Mapping.Time, "timestamp", "updated_at", "created_at"), UpstreamId = Template(config.Mapping.UpstreamId, "eventId", "id") } };
  }
  public async Task SetCredentialAsync(string id, string value, bool reply = false, CancellationToken ct = default)
  {
    var config = Read(id); if (value.Length > 4096 || value.Contains('\0') || value.Contains('\r') || value.Contains('\n')) throw new ArgumentException("Use a bounded single-line source credential.");
    if (value.Length == 0)
    {
      lock (gate)
      {
        var state = State(); config = Read(id); var old = reply ? config.ReplySecretReference : config.SecretReference;
        store.Save(state with { Sources = state.Sources.Where(s => s.SourceId != id).Append(reply ? config with { ReplySecretReference = null } : config with { SecretReference = null }).ToArray(), PendingCredentialDeletes = (state.PendingCredentialDeletes ?? []).Concat(old is null ? [] : new[] { old }).Distinct().ToArray() });
      }
    }
    else
    {
      if (!reply && value.Length < 16) throw new ArgumentException("Use a source secret of at least 16 characters.");
      var next = credentialPrefix + Guid.NewGuid().ToString("N"); var bytes = Encoding.UTF8.GetBytes(value);
      try { await secrets.WriteAsync(next, bytes, ct); } finally { CryptographicOperations.ZeroMemory(bytes); }
      try
      {
        lock (gate)
        {
          var state = State(); config = Read(id); var old = reply ? config.ReplySecretReference : config.SecretReference;
          store.Save(state with { Sources = state.Sources.Where(s => s.SourceId != id).Append(reply ? config with { ReplySecretReference = next } : config with { SecretReference = next }).ToArray(), PendingCredentialDeletes = (state.PendingCredentialDeletes ?? []).Concat(old is null ? [] : new[] { old }).Distinct().ToArray() });
        }
      }
      catch { await secrets.DeleteAsync(next, CancellationToken.None); throw; }
    }
    Changed?.Invoke(); await CleanupCredentialsAsync(ct);
  }
  public async Task<string> GenerateCredentialAsync(string id, CancellationToken ct = default)
  { var value = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_'); await SetCredentialAsync(id, value, ct: ct); return value; }
  public async Task CleanupCredentialsAsync(CancellationToken ct = default)
  {
    string[] pending; lock (gate) pending = State().PendingCredentialDeletes ?? [];
    foreach (var reference in pending)
    {
      try { await secrets.DeleteAsync(reference, ct); lock (gate) { var state = State(); store.Save(state with { PendingCredentialDeletes = (state.PendingCredentialDeletes ?? []).Where(p => p != reference).ToArray() }); } }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { }
    }
  }
  private async Task CleanupCredentialsSafelyAsync() { try { await CleanupCredentialsAsync(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { } }
  private async Task<string> SecretAsync(string? reference, CancellationToken ct)
  {
    if (reference is null) throw new UnauthorizedAccessException("This source has no saved proof credential.");
    var bytes = await secrets.ReadAsync(reference, ct) ?? throw new UnauthorizedAccessException("The source credential is unavailable.");
    try { return Encoding.UTF8.GetString(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  public ReceiverMappedPayload[] Preview(ReceiverWebhook input)
  {
    var config = Read(input.SourceId); var headers = input.Headers.ToDictionary(p => p.Key.ToLowerInvariant(), p => p.Value);
    foreach (var key in headers.Keys.Where(k => k.Equals(config.Proof.Header, StringComparison.OrdinalIgnoreCase) || k is "authorization" or "cookie" or "x-api-key").ToArray()) headers[key] = "[redacted]";
    return ReceiverPayloadMapper.Map(input with { Headers = headers, PathToken = null }, config.Mapping);
  }
  public async Task<ReceiverItem[]> AcceptAsync(ReceiverWebhook input, CancellationToken ct = default)
  {
    var source = Source(input.SourceId); if (!source.Enabled) throw new UnauthorizedAccessException("This source is paused.");
    var config = Read(source.Id); await VerifyAsync(input, config, ct);
    var result = new List<ReceiverItem>();
    var index = 0;
    foreach (var mapped in Preview(input))
    {
      ct.ThrowIfCancellationRequested();
      var item = receiver.Receive(new(source.Id, string.IsNullOrWhiteSpace(mapped.Title) ? source.Name : mapped.Title[..Math.Min(240, mapped.Title.Length)], mapped.Text.Length <= 16000 ? mapped.Text : mapped.Text[..15950] + "\n[Excerpt; complete content is in the payload.]", mapped.Fields.GetValueOrDefault("url"), ExternalId: string.IsNullOrWhiteSpace(mapped.UpstreamId) && input.DeliveryId is null ? null : Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source.Id + "\0" + (string.IsNullOrWhiteSpace(mapped.UpstreamId) ? input.DeliveryId + ":" + index : mapped.UpstreamId))))) { Payload = mapped.Payload });
      if (mapped.Ignored && item.Status is InboxStatus.Unrouted or InboxStatus.Held) { receiver.Dismiss(item.Id); item = receiver.Item(item.Id); }
      result.Add(item); index++;
    }
    return result.ToArray();
  }
  public async Task VerifyAsync(ReceiverWebhook input, ReceiverSourceConfiguration config, CancellationToken ct)
  {
    if (input.Body.Length > 80 * 1024) throw new ArgumentException("Receiver payloads can be at most 80 KB.");
    var headers = new Dictionary<string, string>(input.Headers, StringComparer.OrdinalIgnoreCase); var proof = config.Proof;
    if (proof.IpAllow is { Length: > 0 } && !proof.IpAllow.Any(rule => IpMatches(rule, input.ClientIp))) throw new UnauthorizedAccessException("The sender's address is not allowed for this source.");
    if (proof.Scheme == "none") return;
    var secret = await SecretAsync(config.SecretReference, ct);
    static bool Same(string first, string second) => CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(first)), SHA256.HashData(Encoding.UTF8.GetBytes(second)));
    if (proof.Scheme == "token") { var given = input.PathToken ?? headers.GetValueOrDefault(proof.Header, ""); if (input.PathToken is null && given.StartsWith(proof.Prefix, StringComparison.Ordinal)) given = given[proof.Prefix.Length..]; if (!Same(secret, given)) throw new UnauthorizedAccessException("Source proof did not match."); return; }
    if (proof.Scheme == "basic") { var expected = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes((proof.BasicUser ?? "") + ":" + secret)); if (!Same(expected, headers.GetValueOrDefault(proof.Header, ""))) throw new UnauthorizedAccessException("Source proof did not match."); return; }
    var timestamp = proof.TimestampHeader is null ? "" : headers.GetValueOrDefault(proof.TimestampHeader, "");
    if (proof.SignedPayload.Contains("{timestamp}", StringComparison.Ordinal))
    { if (!long.TryParse(timestamp, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds) || Math.Abs((double)Time.GetUtcNow().ToUnixTimeSeconds() - seconds) > proof.ToleranceSeconds) throw new UnauthorizedAccessException("The signed timestamp is missing or outside the allowed window."); }
    var marker = proof.SignedPayload.IndexOf("{body}", StringComparison.Ordinal); var signed = proof.SignedPayload.Replace("{timestamp}", timestamp, StringComparison.Ordinal);
    if (marker < 0 || signed.Split("{body}", StringSplitOptions.None).Length != 2) throw new ArgumentException("A signed payload must contain {body} once.");
    var pieces = signed.Split("{body}", StringSplitOptions.None); var message = Encoding.UTF8.GetBytes(pieces[0]).Concat(input.Body).Concat(Encoding.UTF8.GetBytes(pieces[1])).ToArray(); var key = Encoding.UTF8.GetBytes(secret);
    try
    {
      var hash = proof.Algorithm switch { "sha1" => HMACSHA1.HashData(key, message), "sha256" => HMACSHA256.HashData(key, message), "sha512" => HMACSHA512.HashData(key, message), _ => throw new ArgumentException("Choose a supported HMAC algorithm.") };
      var signature = headers.GetValueOrDefault(proof.Header, ""); if (!signature.StartsWith(proof.Prefix, StringComparison.Ordinal)) throw new UnauthorizedAccessException("The source signature prefix did not match.");
      byte[] supplied;
      try { supplied = proof.Encoding == "base64" ? Convert.FromBase64String(signature[proof.Prefix.Length..]) : Convert.FromHexString(signature[proof.Prefix.Length..]); }
      catch (FormatException) { throw new UnauthorizedAccessException("The source signature encoding is invalid."); }
      if (!CryptographicOperations.FixedTimeEquals(hash, supplied)) throw new UnauthorizedAccessException("The source signature did not match.");
    }
    finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(message); }
  }
  public static bool IpMatches(string rule, string? address)
  {
    if (!System.Net.IPAddress.TryParse(address, out var actual)) return false;
    var pieces = rule.Split('/'); if (!System.Net.IPAddress.TryParse(pieces[0], out var network)) return false;
    if (actual.IsIPv4MappedToIPv6) actual = actual.MapToIPv4(); if (network.IsIPv4MappedToIPv6) network = network.MapToIPv4();
    var left = actual.GetAddressBytes(); var right = network.GetAddressBytes(); if (left.Length != right.Length) return false;
    var bits = left.Length * 8; if (pieces.Length > 2 || pieces.Length == 2 && (!int.TryParse(pieces[1], out bits) || bits < 0 || bits > left.Length * 8)) return false;
    for (var index = 0; index < left.Length; index++) { var mask = bits >= 8 ? 255 : bits <= 0 ? 0 : 255 << (8 - bits) & 255; if ((left[index] & mask) != (right[index] & mask)) return false; bits -= 8; } return true;
  }
  private static void Validate(ReceiverSourceConfiguration config)
  {
    if (config.Proof.Scheme is not ("token" or "hmac" or "basic" or "none") || config.Proof.Algorithm is not ("sha1" or "sha256" or "sha512") || config.Proof.Encoding is not ("hex" or "base64") || config.Proof.ToleranceSeconds is < 1 or > 3600 || !Regex.IsMatch(config.Proof.Header, "^[A-Za-z0-9_-]{1,128}$")) throw new ArgumentException("Choose valid source proof settings.");
    if (config.Proof.TimestampHeader is { } timestamp && !Regex.IsMatch(timestamp, "^[A-Za-z0-9_-]{1,128}$")) throw new ArgumentException("Choose a valid timestamp header.");
    if (config.Proof.Prefix.Length > 256 || config.Proof.SignedPayload.Length > 256 || config.Proof.SignedPayload.Contains('\0') || (config.Proof.IpAllow?.Length ?? 0) > 64) throw new ArgumentException("Keep proof templates and address lists bounded.");
    if (config.Proof.Scheme == "hmac" && config.Proof.SignedPayload.Split("{body}", StringSplitOptions.None).Length != 2) throw new ArgumentException("Signed payloads must include {body} exactly once.");
    if ((config.Mapping.Fields?.Count ?? 0) > 64 || (config.Mapping.Overrides?.Count ?? 0) > 64 || (config.Mapping.Ignore?.Length ?? 0) > 64) throw new ArgumentException("Keep field maps and ignore conditions below 64 rows.");
    foreach (var condition in config.Mapping.Ignore ?? []) ReceiverConditions.Validate(condition);
    foreach (var template in new[] { config.Mapping.Kind, config.Mapping.Severity, config.Mapping.Title, config.Mapping.Text, config.Mapping.Time, config.Mapping.UpstreamId }.Concat((config.Mapping.Fields ?? []).Values).Concat((config.Mapping.Overrides ?? []).Values)) if (template.Length > 8000 || template.Contains('\0')) throw new ArgumentException("Use bounded mapping templates.");
    if (config.Reply is { } reply && (reply.Via is not ("http" or "github") || reply.Method is not ("POST" or "PUT" or "PATCH") || reply.Body.Length > 24000 || (reply.Headers?.Count ?? 0) > 32)) throw new ArgumentException("Choose a supported bounded reply channel.");
  }
}
