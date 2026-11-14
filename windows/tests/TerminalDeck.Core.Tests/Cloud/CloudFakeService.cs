using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// A fake Cloud service for W3 that applies the service's OWN checks (cloud/worker/src user.ts handle / transfer,
// feed.ts commit / changes / applied, its error shape): bearer token, device proof over the exact bytes, the one-minute
// clock window with `clock_skew` + serverTime, request-id replay (same id + same fingerprint = the saved answer, other
// bytes = 409 id_reused), the pack signature over canonical(descriptor without signature) + "\n" + subject, the
// ciphertext hash, and single-use transfer proofs with X-TD-Content-SHA256.
internal sealed class CloudFakeService : ICloudSyncHttp
{
  public const string Subject = "38fdae8d-01e6-432d-b2c9-d40fe9996b5f";
  public static readonly Uri Base = new("https://cloud.td.test/v1");
  public static readonly byte[] BrainKey = Convert.FromHexString("4bdff7222adbea4e528a32a74da613179cfccb4e75125cc398de22fb1a5ed75c");
  public long Now = 1_763_000_000_000;
  public int FailNext;
  /// The next requests answer 429 with this `Retry-After` (seconds), as the service's slow-down does.
  public int RateLimitNext; public long RateLimitRetryAfterSeconds = 5;
  public bool LoseNextCommitAnswer;
  public string? RefuseCommitsWith;
  /// The next commits are refused as too large (422 payload_too_large); the refused pack ids are kept here.
  public int RefuseNextCommits; public readonly List<string> RefusedSegmentIds = [];
  public int Requests;
  public readonly List<string> Log = [];
  public readonly Dictionary<string, ECDsa> Devices = new(StringComparer.Ordinal);
  public readonly Dictionary<string, string> Tokens = new(StringComparer.Ordinal);
  public readonly HashSet<ulong> ExpiredLinks = [];
  public readonly Dictionary<ulong, Func<CloudJson.Object, CloudJson.Object>> Tamper = [];
  public string? Checkpoint;
  public ulong FirstSeq = 1;
  private readonly List<(ulong Seq, CloudJson.Object Descriptor, string Device, long CreatedAt, byte[] Bytes)> segments = [];
  private readonly Dictionary<string, (string Device, string Fingerprint, int Status, byte[] Body)> saved = new(StringComparer.Ordinal);
  private readonly HashSet<string> transferIds = [];
  public ulong Head => segments.Count == 0 ? FirstSeq - 1 : segments[^1].Seq;
  public int Segments => segments.Count;
  public IReadOnlyList<string> SegmentIds => segments.Select(s => s.Descriptor["segmentId"]!.AsString!).ToArray();
  public (string Device, ulong Applied) LastApplied;

  public void Register(string deviceId, ECDsa key, string token) { Devices[deviceId] = key; Tokens[deviceId] = token; }

  public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    Requests++;
    Log.Add(request.Method + " " + request.Url.PathAndQuery);
    if (FailNext > 0) { FailNext--; return Task.FromResult(Error(503, "temporarily_unavailable", true)); }
    if (RateLimitNext > 0) { RateLimitNext--; return Task.FromResult(Error(429, "rate_limited", true) with { RetryAfterSeconds = RateLimitRetryAfterSeconds }); }
    try { return Task.FromResult(Handle(request)); }
    catch (Fault fault) { return Task.FromResult(Error(fault.Status, fault.Code, fault.Retryable, fault.ServerTime)); }
  }

  private sealed class Fault(int status, string code, bool retryable = false, long? serverTime = null) : Exception(code)
  {
    public int Status { get; } = status; public string Code { get; } = code; public bool Retryable { get; } = retryable; public long? ServerTime { get; } = serverTime;
  }
  private static void Check(bool ok, string code = "invalid_request", int status = 400) { if (!ok) throw new Fault(status, code); }
  private static CloudSyncHttpResponse Json(CloudJson value, int status = 200) => new(status, CloudCanonical.Encode(value));
  private static CloudSyncHttpResponse Error(int status, string code, bool retryable, long? serverTime = null) =>
    Json(CloudJson.Obj(("error", CloudJson.Obj(("code", CloudJson.From(code)), ("message", CloudJson.From("x")), ("retryable", CloudJson.From(retryable)),
      ("serverTime", serverTime is { } s ? CloudJson.From(s) : null), ("requestId", CloudJson.From(""))))), status);
  private static string H(CloudSyncHttpRequest r, string name) => r.Headers.FirstOrDefault(h => h.Key.Equals(name, StringComparison.OrdinalIgnoreCase)).Value ?? "";

  private void ClockWithin(string time)
  {
    Check(time.Length == 13 && time.All(char.IsAsciiDigit), "bad_device_proof", 401);
    if (Math.Abs(long.Parse(time, CultureInfo.InvariantCulture) - Now) > 60_000) throw new Fault(400, "clock_skew", true, Now);
  }
  private static bool Verify(ECDsa key, string signature, string message)
  {
    try { var raw = CloudBytes.Unbase64(signature); return raw.Length == 64 && key.VerifyData(Encoding.UTF8.GetBytes(message), raw, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation); }
    catch (CloudFailure) { return false; }
  }

  private CloudSyncHttpResponse Handle(CloudSyncHttpRequest r)
  {
    var path = r.Url.AbsolutePath;
    if (path.StartsWith("/v1/transfers/", StringComparison.Ordinal)) return Transfer(r);
    var device = H(r, "X-TD-Device");
    Check(Devices.TryGetValue(device, out var key), "not_found", 404);
    Check(H(r, "Authorization") == "Bearer " + Tokens[device], "sign_in_required", 401);
    var time = H(r, "X-TD-Time");
    ClockWithin(time);
    var requestId = H(r, "X-TD-Request");
    Check(Guid.TryParse(requestId, out _));
    var raw = Encoding.UTF8.GetString(r.Body);
    Check(Verify(key!, H(r, "X-TD-Signature"), $"TD-CLOUD-1\n{r.Method}\n{r.Url.AbsolutePath}{r.Url.Query}\n{time}\n{requestId}\n{CloudBytes.Sha256Hex(r.Body)}"), "bad_device_proof", 401);
    var fingerprint = CloudBytes.Sha256Hex(Encoding.UTF8.GetBytes($"{r.Method}\n{r.Url.AbsolutePath}{r.Url.Query}\n{raw}"));
    if (saved.TryGetValue(requestId, out var old))
    {
      Check(old.Device == device && old.Fingerprint == fingerprint, "id_reused", 409);
      if (path != "/v1/brain-key") return new(old.Status, old.Body);
    }
    var value = raw.Length > 0 ? CloudJson.Parse(raw) as CloudJson.Object ?? throw new Fault(400, "invalid_request") : CloudJson.Obj();
    var route = path[3..];
    CloudSyncHttpResponse answer;
    if (route == "/changes" && r.Method == "POST") answer = Commit(value, device, requestId);
    else if (route == "/changes" && r.Method == "GET") answer = Changes(r.Url.Query);
    else if (route == "/applied" && r.Method == "POST")
    {
      LastApplied = (device, ulong.Parse(value["brainSeq"]!.AsString!, CultureInfo.InvariantCulture));
      answer = Json(CloudJson.Obj(("brainSeq", value["brainSeq"]), ("secretsSeq", value["secretsSeq"])));
    }
    else if (route == "/checkpoints/current" && r.Method == "GET")
      answer = Json(CloudJson.Obj(("checkpoint", Checkpoint is null ? CloudJson.Null.Value : CloudJson.Obj(("checkpointId", CloudJson.From(Checkpoint)), ("throughSeq", CloudJson.From("1"))))));
    else if (route == "/brain-key" && r.Method == "POST") answer = Json(CloudJson.Obj(("epoch", CloudJson.From(1)), ("key", CloudJson.From(CloudBytes.Base64Url(BrainKey)))));
    else throw new Fault(404, "not_found");
    if (r.Method != "GET" && answer.Status < 300) saved[requestId] = (device, fingerprint, answer.Status, answer.Body);
    if (route == "/changes" && r.Method == "POST" && LoseNextCommitAnswer) { LoseNextCommitAnswer = false; throw new HttpRequestException("connection reset after commit"); }
    return answer;
  }

  private CloudSyncHttpResponse Commit(CloudJson.Object value, string device, string requestId)
  {
    if (RefuseCommitsWith is { } code) throw new Fault(422, code);
    var d = value["descriptor"] as CloudJson.Object ?? throw new Fault(400, "invalid_request");
    if (RefuseNextCommits > 0) { RefuseNextCommits--; RefusedSegmentIds.Add(d["segmentId"]!.AsString!); throw new Fault(422, "payload_too_large"); }
    Check(d["requestId"]?.AsString == requestId);
    Check(d["format"]?.AsString == "td-ops-1", "unsupported_format", 422);
    var ciphertext = CloudBytes.Unbase64(value["ciphertext"]?.AsString ?? "");
    Check(ciphertext.Length == d["bytes"]?.AsInteger && CloudBytes.Sha256Hex(ciphertext) == d["sha256"]?.AsString, "checksum_mismatch", 422);
    Check(Verify(Devices[device], d["signature"]!.AsString!, Encoding.UTF8.GetString(CloudCanonical.Encode(d.Without("signature"))) + "\n" + Subject), "bad_device_proof", 401);
    var segmentId = d["segmentId"]!.AsString!;
    if (segments.FirstOrDefault(s => s.Descriptor["segmentId"]!.AsString == segmentId) is { Descriptor: not null } existing)
    {
      Check(existing.Device == device && CloudCanonical.Encode(existing.Descriptor).SequenceEqual(CloudCanonical.Encode(d)), "id_reused", 409);
      return Receipt(existing.Seq, d, existing.CreatedAt);
    }
    var seq = Head + 1;
    segments.Add((seq, d, device, Now, ciphertext));
    return Receipt(seq, d, Now);
  }
  private CloudSyncHttpResponse Receipt(ulong seq, CloudJson.Object d, long at) => Json(CloudJson.Obj(("segmentId", d["segmentId"]), ("seq", S(seq)), ("headSeq", S(Head)),
    ("receipt", CloudJson.Obj(("requestId", d["requestId"]), ("sha256", d["sha256"]), ("committedAt", CloudJson.From(at))))));
  private static CloudJson S(ulong v) => CloudJson.From(v.ToString(CultureInfo.InvariantCulture));

  private CloudSyncHttpResponse Changes(string query)
  {
    var parts = query.TrimStart('?').Split('&').Select(p => p.Split('=')).ToDictionary(p => p[0], p => p[1]);
    Check(parts.Keys.All(k => k is "after" or "limit"));
    var after = ulong.Parse(parts["after"], CultureInfo.InvariantCulture);
    var limit = int.Parse(parts["limit"], CultureInfo.InvariantCulture);
    Check(limit is >= 1 and <= 128 && after <= Head);
    var rows = segments.Where(s => s.Seq > after).Take(limit + 1).ToArray();
    var page = rows.Take(limit).ToArray();
    var entries = page.Select(s =>
    {
      var entry = CloudJson.Obj(s.Descriptor.Members.Select(m => (m.Key, (CloudJson?)m.Value)).Concat([("seq", (CloudJson?)S(s.Seq)), ("deviceId", CloudJson.From(s.Device)),
        ("createdAt", CloudJson.From(s.CreatedAt)), ("getUrl", CloudJson.From(Base + "/transfers/seg/" + s.Seq.ToString(CultureInfo.InvariantCulture) + "?t=1")),
        ("expiresAt", CloudJson.From(Now + 60_000))]).ToArray());
      return (CloudJson)(Tamper.TryGetValue(s.Seq, out var change) ? change(entry) : entry);
    }).ToArray();
    return Json(CloudJson.Obj(("segments", CloudJson.Arr(entries)), ("headSeq", S(Head)), ("nextAfter", S(page.Length > 0 ? page[^1].Seq : after)), ("hasMore", CloudJson.From(rows.Length > limit))));
  }

  private CloudSyncHttpResponse Transfer(CloudSyncHttpRequest r)
  {
    var device = H(r, "X-TD-Device");
    Check(Devices.TryGetValue(device, out var key), "not_found", 404);
    var time = H(r, "X-TD-Time");
    ClockWithin(time);
    var id = H(r, "X-TD-Request");
    var hash = H(r, "X-TD-Content-SHA256");
    Check(hash.Length == 64, "bad_device_proof", 401);
    Check(Verify(key!, H(r, "X-TD-Signature"), $"TD-CLOUD-1\n{r.Method}\n{r.Url.AbsolutePath}{r.Url.Query}\n{time}\n{id}\n{hash}"), "bad_device_proof", 401);
    Check(r.Method != "GET" || hash == CloudBytes.Sha256Hex([]), "checksum_mismatch", 422);
    Check(transferIds.Add(id), "transfer_proof_reused", 409);
    var seq = ulong.Parse(r.Url.AbsolutePath.Split('/')[^1], CultureInfo.InvariantCulture);
    if (ExpiredLinks.Remove(seq)) return new(404, []);
    var segment = segments.First(s => s.Seq == seq);
    return new(200, segment.Bytes);
  }
}

/// The device's own side for tests: bearer token, the TD-CLOUD-1 proof (any method), ES256 pack signatures.
internal sealed class CloudTestDevice : ICloudSyncAuth
{
  public string DeviceId { get; }
  public ECDsa Key { get; } = ECDsa.Create(ECCurve.NamedCurves.nistP256);
  public string Token { get; } = "token-" + Guid.NewGuid().ToString("N");
  public CloudTestDevice(string deviceId, CloudFakeService service) { DeviceId = deviceId; service.Register(deviceId, Key, Token); }
  public CloudPublicJwk Jwk
  {
    get { var q = Key.ExportParameters(false).Q; return new("EC", "P-256", CloudBytes.Base64Url(q.X), CloudBytes.Base64Url(q.Y)); }
  }
  public Task<CloudSyncCredentials> CredentialsAsync(CancellationToken ct) => Task.FromResult(new CloudSyncCredentials(CloudFakeService.Subject, Token, long.MaxValue, DeviceId));
  public IReadOnlyDictionary<string, string> Proof(string method, string pathAndQuery, byte[] body, long timeMs, string requestId)
  {
    var message = Encoding.UTF8.GetBytes($"TD-CLOUD-1\n{method}\n{pathAndQuery}\n{timeMs.ToString(CultureInfo.InvariantCulture)}\n{requestId}\n{CloudBytes.Sha256Hex(body)}");
    return new Dictionary<string, string> { ["X-TD-Device"] = DeviceId, ["X-TD-Time"] = timeMs.ToString(CultureInfo.InvariantCulture), ["X-TD-Request"] = requestId,
      ["X-TD-Signature"] = CloudBytes.Base64Url(Key.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)) };
  }
  public byte[] Sign(byte[] bytes) => Key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
}

internal sealed class CloudTestTrust : ICloudDeviceTrust
{
  public readonly Dictionary<string, CloudPublicJwk> Trusted = new(StringComparer.Ordinal);
  public CloudPublicJwk? TrustedSigningKey(string deviceId) => Trusted.GetValueOrDefault(deviceId);
}

internal sealed class CloudMemorySlot : ICloudLedgerSlot
{
  public byte[]? Bytes;
  public bool FailWrites;
  public byte[]? Read() => Bytes?.ToArray();
  public void Write(byte[] bytes) { if (FailWrites) throw new IOException("disk full"); Bytes = bytes.ToArray(); }
}

/// A record owner for engine tests: queued texts become records of `brain/test`; applied records are counted by id.
internal sealed class CloudTestAdapter(string deviceId, string domain = "brain/test") : ICloudSyncAdapter
{
  private readonly List<CloudOperation> queued = [];
  public readonly List<(string Text, CloudImportOrigin Origin)> Applied = [];
  private readonly HashSet<string> held = new(StringComparer.Ordinal);
  public Func<CloudOperation, bool>? CrashOn;
  /// A record this owner refuses for good (Mac X1(b)): the engine passes it over and the feed moves on.
  public Func<CloudOperation, bool>? RefuseOn;
  /// Completes when the first record is applied, so a test awaits it instead of sleeping.
  public readonly TaskCompletionSource FirstApplied = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public IReadOnlyCollection<string> Domains => [domain];
  public void Add(string text) => queued.Add(CloudOperation.Create(deviceId, domain, "entity-" + text, [], "put", new("test", text), 1_763_000_000_000, CloudJson.Obj(("text", CloudJson.From(text)))));
  public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    var taken = queued.ToArray();
    return Task.FromResult(new CloudCapture(taken, () => queued.RemoveAll(taken.Contains)));
  }
  public Task ApplyAsync(CloudOperation operation, CloudImportOrigin origin, CancellationToken ct)
  {
    if (CrashOn?.Invoke(operation) == true) throw new InvalidOperationException("the app stopped here");
    if (RefuseOn?.Invoke(operation) == true) throw new CloudFailure("id_reused");
    if (held.Add(operation.OpId)) { Applied.Add(((operation.Payload as CloudJson.Object)!["text"]!.AsString!, origin)); FirstApplied.TrySetResult(); }
    return Task.CompletedTask;
  }
}
