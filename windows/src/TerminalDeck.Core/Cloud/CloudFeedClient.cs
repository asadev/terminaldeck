using System.Globalization;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// W3 transport: the signed control calls of the change feed (the Mac's CloudSyncTransport.swift; the contract is the
// service's feed.ts / user.ts / blobs.ts). Every control request carries the bearer token and the device proof
// (`TD-CLOUD-1\n{method}\n{path and query}\n{time}\n{request id}\n{sha256 of body}`), a request id that is kept until
// the service answered (a retry is the same request), and goes through one back-off. A request this PC cancelled itself
// is never counted as a failure; a success clears the back-off.

/// What the transport needs from the signed-in account. Windows wiring: CloudAccountClient's saved session and
/// CloudDeviceKeys.Proof (GET, POST, and PUT for blob uploads), through CloudAccountClient (ICloudSyncAccount).
public sealed record CloudSyncCredentials(string UserId, string AccessToken, long ExpiresAt, string DeviceId)
{
  public override string ToString() => "<Cloud sync credentials>";
}
public interface ICloudSyncAuth
{
  Task<CloudSyncCredentials> CredentialsAsync(CancellationToken ct);
  IReadOnlyDictionary<string, string> Proof(string method, string pathAndQuery, byte[] body, long timeMs, string requestId);
}

/// Raw HTTP for sync: any method, content headers allowed, bounded answers, no redirects.
public sealed record CloudSyncHttpRequest(string Method, Uri Url, IReadOnlyDictionary<string, string> Headers, byte[] Body, int MaximumAnswerBytes)
{
  public override string ToString() => Method + " " + Url.AbsolutePath;
}
public sealed record CloudSyncHttpResponse(int Status, byte[] Body, long? RetryAfterSeconds = null);
public interface ICloudSyncHttp { Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken ct); }

/// The event connection (`GET /v1/events` upgraded to a web socket). Frames are text.
public interface ICloudSyncSocket : IAsyncDisposable
{
  Task<string?> ReceiveAsync(CancellationToken ct);
  Task SendAsync(string text, CancellationToken ct);
}
public interface ICloudSyncSocketFactory { Task<ICloudSyncSocket> ConnectAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct); }

/// Small durable values the transport keeps (request ids of unanswered calls, the clock correction). The sync store.
public interface ICloudSyncMetadata
{
  string? Get(string key);
  void Set(string key, string? value);
}

/// Where the service lives. Production is fixed; TEST hosts must say so in their name. Transfer links must stay on
/// the service's own host under `/v1/transfers/`.
public sealed class CloudSyncEndpoint
{
  public Uri Base { get; }
  public bool Test { get; }
  public CloudSyncEndpoint(Uri @base, bool test)
  {
    if (@base.Scheme != "https" || @base.UserInfo.Length > 0 || @base.Query.Length > 0 || @base.Fragment.Length > 0 || @base.AbsolutePath != "/v1")
      throw new CloudFailure("unsafe_configuration");
    if (!test && @base.AbsoluteUri.TrimEnd('/') != CloudWire.ProductionBase) throw new CloudFailure("unsafe_configuration");
    if (test && (@base.Host == new Uri(CloudWire.ProductionBase).Host || !(@base.Host.EndsWith(".test", StringComparison.Ordinal) || @base.Host.Contains("td-cloud-test", StringComparison.Ordinal))))
      throw new CloudFailure("unsafe_configuration");
    Base = @base; Test = test;
  }
  public Uri Control(string pathAndQuery) => new(Base.GetLeftPart(UriPartial.Authority) + "/v1" + pathAndQuery);
  public void PermitObject(Uri url)
  {
    if (url.Scheme != "https" || url.Host != Base.Host || url.Port != Base.Port || !url.AbsolutePath.StartsWith("/v1/transfers/", StringComparison.Ordinal)
      || url.UserInfo.Length > 0 || url.Fragment.Length > 0) throw new CloudFailure("unsafe_configuration");
  }
}

/// How a refusal is handled (the Mac's CloudSyncTransport / CloudSyncBudget classes).
public enum CloudRefusalKind
{
  /// Nothing went wrong on the service: this PC cancelled the request.
  Cancelled,
  /// The account or this device: sign in again, device removed, bad device proof. Sync stops until signed in.
  Account,
  /// The service refused this one pack for good (its content, size or ids). The engine splits or parks it.
  PackOnly,
  /// Saved passwords only (secrets_locked, rotation_required). Memory goes on.
  SecretsLocked,
  /// The daily allowance or rate limit: wait until the stated time.
  Budget,
  /// Gate closed: Cloud is not allowed for this account.
  Gate,
  /// Network, timeouts, 5xx, a lost answer: retried with back-off.
  Transient,
  /// The service refused for good in a way that is not about one pack.
  Remote,
  /// This PC's clock is too far off and one corrected retry did not help.
  ClockSkew
}

public static class CloudRefusal
{
  public static readonly IReadOnlySet<string> AccountCodes = new HashSet<string> { "sign_in_required", "token_expired", "bad_device_proof", "device_revoked", "not_found" };
  public static readonly IReadOnlySet<string> PackOnlyCodes = new HashSet<string> { "invalid_request", "unsupported_format", "payload_too_large", "checksum_mismatch", "id_reused" };
  public static readonly IReadOnlySet<string> ProtectedOnlyCodes = new HashSet<string> { "secrets_locked", "rotation_required" };
  public static readonly IReadOnlySet<string> BudgetCodes = new HashSet<string> { "budget_paused", "rate_limited", "1102", "1027", "sql_quota_exceeded" };

  /// `packScoped`: the request was a pack commit (only then can a code be about the pack alone).
  public static CloudRefusalKind Classify(Exception error, bool packScoped = false)
  {
    if (error is OperationCanceledException) return CloudRefusalKind.Cancelled;
    if (error is not CloudFailure f) return CloudRefusalKind.Transient;
    if (f.Code == "clock_skew") return CloudRefusalKind.ClockSkew;
    if (ProtectedOnlyCodes.Contains(f.Code)) return CloudRefusalKind.SecretsLocked;
    if (f.Code == "gate_closed") return CloudRefusalKind.Gate;
    if (BudgetCodes.Contains(f.Code) || f.Status == 429) return CloudRefusalKind.Budget;
    if (AccountCodes.Contains(f.Code) || f.Status is 401 or 403) return CloudRefusalKind.Account;
    if (packScoped && !f.Retryable && PackOnlyCodes.Contains(f.Code) && f.Status is >= 400 and < 500) return CloudRefusalKind.PackOnly;
    if (f.Retryable || f.Status == 0 || f.Status >= 500 || f.Code is "unavailable" or "invalid_response") return CloudRefusalKind.Transient;
    return CloudRefusalKind.Remote;
  }
  /// The one plain word a log line uses for a failure (`cloud sync: <what> failed: <kind>`).
  public static string Word(CloudRefusalKind kind) => kind switch
  {
    CloudRefusalKind.Account => "sign-in", CloudRefusalKind.PackOnly => "refused-pack", CloudRefusalKind.SecretsLocked => "saved-passwords-locked",
    CloudRefusalKind.Budget => "budget", CloudRefusalKind.Gate => "not-allowed", CloudRefusalKind.Transient => "network",
    CloudRefusalKind.Remote => "refused", CloudRefusalKind.ClockSkew => "clock", _ => "cancelled"
  };
}

/// The shared back-off (CloudSyncBudget.failed / succeeded / resume). Kept in the sync store so a restart keeps it.
public sealed class CloudSyncBackoff(ICloudSyncMetadata metadata, Func<long> now, Func<int, int>? jitter = null)
{
  private static readonly long[] Delays = [1000, 2000, 4000, 8000, 16000, 30000, 60000];
  private readonly Func<int, int> jitter = jitter ?? (max => Random.Shared.Next(0, max + 1));
  public int Failures => int.TryParse(metadata.Get("backoff.failures"), out var v) ? v : 0;
  public long RetryAt => long.TryParse(metadata.Get("backoff.retryAt"), out var v) ? v : 0;
  /// null, "network" (five failures in a row), "rate", "budget", "auth", "remote", "gate".
  public string? Blocked => metadata.Get("backoff.blocked");
  /// False while a stop needs the person (auth, remote, gate) or a timed wait has not passed.
  public bool MaySend => Blocked is not ("auth" or "remote" or "gate") && now() >= RetryAt;

  private void Save(int failures, long retryAt, string? blocked)
  {
    metadata.Set("backoff.failures", failures.ToString(CultureInfo.InvariantCulture));
    metadata.Set("backoff.retryAt", retryAt.ToString(CultureInfo.InvariantCulture));
    metadata.Set("backoff.blocked", blocked);
  }
  /// A failed step. A cancellation by this PC never counts; comparison outcomes (`id_reused`, version changes) and
  /// a pack refused for good are the engine's to handle and do not pace the account.
  public void Failed(Exception error, long? retryAfterMs = null, bool packScoped = false)
  {
    var kind = CloudRefusal.Classify(error, packScoped);
    if (kind is CloudRefusalKind.Cancelled or CloudRefusalKind.PackOnly or CloudRefusalKind.SecretsLocked) return;
    if (error is CloudFailure { Code: "baseline_changed" or "version_changed" or "id_reused" }) return;
    var failures = Math.Min(Failures + 1, 1000);
    var t = now();
    switch (kind)
    {
      case CloudRefusalKind.Budget when error is CloudFailure { Code: "rate_limited" } or CloudFailure { Status: 429, Code: not "budget_paused" }:
        Save(failures, Math.Max(t + 1000, retryAfterMs is { } r ? t + r : t + 60_000), "rate"); return;
      case CloudRefusalKind.Budget:
        Save(failures, Math.Max(retryAfterMs is { } b ? t + b : 0, (t / 86_400_000 + 1) * 86_400_000), "budget"); return;
      case CloudRefusalKind.Account: Save(failures, 0, "auth"); return;
      case CloudRefusalKind.Gate: Save(failures, 0, "gate"); return;
      case CloudRefusalKind.Remote: Save(failures, 0, "remote"); return;
      default:
        var delay = Delays[Math.Min(failures - 1, Delays.Length - 1)] + jitter(500);
        Save(failures, Math.Max(retryAfterMs is { } w ? t + w : 0, t + delay), failures >= 5 ? "network" : Blocked is "network" ? "network" : null);
        return;
    }
  }
  /// Any answered step clears the count; a stop that needs the person (auth, remote, gate) stays until `Resume`.
  public void Succeeded()
  {
    var blocked = Blocked;
    if (blocked is "network" or "rate" or null) Save(0, 0, null);
    else Save(0, RetryAt, blocked);
  }
  /// The network returned, the PC woke, the person signed in again or pressed Try again.
  public void Resume(bool networkOrWake = false, bool signedIn = false, bool userRetry = false)
  {
    var blocked = Blocked;
    if (blocked is null || (networkOrWake || userRetry) && blocked == "network" || signedIn && blocked == "auth"
      || (networkOrWake || signedIn || userRetry) && blocked == "rate" && now() >= RetryAt || (signedIn || userRetry) && blocked is "remote" or "gate")
      Save(0, 0, null);
  }
}

// ---- Wire records (field names exactly as the service sends them) ----

public sealed record CloudCommitReceipt(string SegmentId, ulong Seq, ulong HeadSeq, string RequestId, string Sha256, long CommittedAt);
/// One feed entry as the service lists it (feed.ts `changes`): the descriptor fields flattened, the device the service
/// recorded, a one-minute download link. A locked entry (saved passwords this device cannot open) has seq and class only.
public sealed record CloudChangeEntry(ulong Seq, string StorageClass, bool Locked, string? DeviceId, long? CreatedAt, Uri? GetUrl, long? ExpiresAt,
  CloudSegmentDescriptor? Descriptor, string? SegmentId, string? Sha256, long? Bytes)
{
  public CloudFeedEntry ToFeedEntry() => new(Seq, StorageClass, DeviceId, Descriptor, Locked, CreatedAt);
}
public sealed record CloudChangePage(IReadOnlyList<CloudChangeEntry> Segments, ulong HeadSeq, ulong NextAfter, bool HasMore);
public sealed record CloudBlobUpload(string UploadId, string BlobId, string StorageClass, string Purpose, int KeyEpoch, long Bytes, string Sha256, string Md5)
{
  public CloudJson ToJson() => CloudJson.Obj(("uploadId", CloudJson.From(UploadId)), ("blobId", CloudJson.From(BlobId)), ("class", CloudJson.From(StorageClass)),
    ("purpose", CloudJson.From(Purpose)), ("keyEpoch", CloudJson.From(KeyEpoch)), ("bytes", CloudJson.From(Bytes)), ("sha256", CloudJson.From(Sha256)), ("md5", CloudJson.From(Md5)));
}
public sealed record CloudBlobTicket(string UploadId, string BlobId, Uri? PutUrl, IReadOnlyDictionary<string, string> Headers, string Ticket, long ExpiresAt, bool AlreadyPresent);
public sealed record CloudBlobResult(string UploadId, CloudJson? Blob, string? ErrorCode, bool ErrorRetryable);
public sealed record CloudBlobDownload(CloudJson Blob, string BlobId, Uri GetUrl, long ExpiresAt);
public sealed record CloudSyncEvent(string Type, string Id, CloudJson Payload);
public sealed record CloudCurrentCheckpoint(string CheckpointId, ulong ThroughSeq);

/// The transport. One instance per signed-in account and device; never shared across accounts.
public sealed class CloudFeedClient
{
  public const int MaximumControlBytes = 409_600, MaximumSegmentBytes = 262_144, FeedPageLimit = 128;
  private readonly CloudSyncEndpoint endpoint;
  private readonly ICloudSyncAuth auth;
  private readonly ICloudSyncHttp http;
  private readonly ICloudSyncMetadata metadata;
  private readonly Func<long> clock;
  private readonly string subject;
  public CloudSyncBackoff Backoff { get; }
  /// The service's clock as learned from a clock_skew answer or a commit receipt (ms). Null until known.
  public long? ServiceOffset => long.TryParse(metadata.Get("signingClockOffset"), out var v) ? v : null;
  public long ServiceNow() => clock() + (ServiceOffset ?? 0);

  public CloudFeedClient(CloudSyncEndpoint endpoint, string subject, ICloudSyncAuth auth, ICloudSyncHttp http, ICloudSyncMetadata metadata, Func<long>? clock = null, CloudSyncBackoff? backoff = null)
  {
    this.endpoint = endpoint; this.subject = subject; this.auth = auth; this.http = http; this.metadata = metadata;
    this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    Backoff = backoff ?? new CloudSyncBackoff(metadata, this.clock);
  }

  // ---- The one way a control request leaves this PC ----

  private async Task<CloudJson> CallAsync(string method, string pathAndQuery, CloudJson? body, string? id, bool packScoped, CancellationToken ct, bool fresh = false)
  {
    if (!pathAndQuery.StartsWith('/') || pathAndQuery.Contains("..", StringComparison.Ordinal)) throw new CloudFailure("invalid_request");
    var bytes = method == "GET" ? [] : CloudCanonical.Encode(body ?? CloudJson.Obj());
    if (bytes.Length > MaximumControlBytes) throw new CloudFailure("invalid_request");
    var credentials = await Guard(() => auth.CredentialsAsync(ct), ct);
    if (credentials.UserId != subject) throw new CloudFailure("unsafe_configuration");
    // A logical attempt keeps its id until answered, so a retry after a lost answer is the same request to the service.
    var key = "request:" + credentials.DeviceId + ":" + CloudBytes.Sha256Hex([.. Encoding.UTF8.GetBytes(method + pathAndQuery), .. bytes]);
    string requestId;
    if (id is not null) requestId = id;
    else if (method != "GET")
    {
      if (!fresh && metadata.Get(key) is { } previous) requestId = previous;
      else { requestId = CloudBytes.NewTransportId(); metadata.Set(key, requestId); }
    }
    else requestId = CloudBytes.NewTransportId();
    CloudBytes.TransportId(requestId);
    var answer = await SendAsync(method, pathAndQuery, bytes, requestId, credentials, packScoped, ct);
    if (method != "GET" && id is null) metadata.Set(key, null);
    try { return CloudJson.Parse(answer); }
    catch (CloudFailure) { Backoff.Failed(new CloudFailure("invalid_response")); throw new CloudFailure("invalid_response"); }
  }

  private async Task<byte[]> SendAsync(string method, string pathAndQuery, byte[] bytes, string requestId, CloudSyncCredentials credentials, bool packScoped, CancellationToken ct)
  {
    var sentAt = clock();
    try { return await AttemptAsync(method, pathAndQuery, bytes, requestId, credentials, packScoped, skewRetry: true, ct); }
    catch (ClockSkew skew)
    {
      // The service refused this PC's clock and stated its own: correct the signing time from that answer and send the
      // SAME request (same id, same bytes) once more. A second refusal is an ordinary failure.
      var receivedAt = clock();
      metadata.Set("signingClockOffset", (skew.ServerTime - (sentAt + Math.Max(0, receivedAt - sentAt) / 2)).ToString(CultureInfo.InvariantCulture));
      return await AttemptAsync(method, pathAndQuery, bytes, requestId, credentials, packScoped, skewRetry: false, ct);
    }
  }

  private sealed class ClockSkew(long serverTime) : Exception("clock skew") { public long ServerTime { get; } = serverTime; }

  private async Task<byte[]> AttemptAsync(string method, string pathAndQuery, byte[] bytes, string requestId, CloudSyncCredentials credentials, bool packScoped, bool skewRetry, CancellationToken ct)
  {
    var time = ServiceNow();
    var full = "/v1" + pathAndQuery;
    var proof = auth.Proof(method, full, bytes, time, requestId);
    if (!proof.TryGetValue("X-TD-Device", out var device) || device != credentials.DeviceId) throw new CloudFailure("invalid_request");
    var headers = new Dictionary<string, string>(proof, StringComparer.OrdinalIgnoreCase)
    {
      ["Authorization"] = "Bearer " + credentials.AccessToken, ["Cache-Control"] = "no-store", ["Content-Type"] = "application/json"
    };
    var response = await Guard(() => http.SendAsync(new(method, endpoint.Control(pathAndQuery), headers, bytes, MaximumControlBytes), ct), ct);
    if (response.Status is >= 200 and < 300) { Backoff.Succeeded(); return response.Body; }
    var detail = ErrorDetail(response.Body);
    if (skewRetry && response.Status == 400 && detail.Code == "clock_skew" && detail.ServerTime is > 0) throw new ClockSkew(detail.ServerTime.Value);
    var failure = new CloudFailure(detail.Code ?? "unavailable", response.Status, detail.Retryable ?? response.Status is >= 500 or 429);
    var retryAfter = response.RetryAfterSeconds is { } s ? s * 1000 : detail.RetryAfterMs;
    Backoff.Failed(failure, retryAfter, packScoped);
    throw failure;
  }

  /// Network faults are counted once; a cancellation by this PC is not counted at all.
  private async Task<T> Guard<T>(Func<Task<T>> step, CancellationToken ct)
  {
    try { return await step(); }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
    catch (CloudFailure) { throw; }
    catch (Exception ex) when (ex is HttpRequestException or IOException or OperationCanceledException or WebSocketException)
    {
      var failure = new CloudFailure("unavailable", 0, true);
      Backoff.Failed(failure);
      throw failure;
    }
  }

  private sealed record Detail(string? Code, bool? Retryable, long? RetryAfterMs, long? ServerTime);
  private static Detail ErrorDetail(byte[] body)
  {
    try
    {
      if (CloudJson.Parse(body) is CloudJson.Object o && o["error"] is CloudJson.Object e)
        return new(e["code"]?.AsString, e["retryable"] is CloudJson.Bool b ? b.Value : null, e["retryAfterMs"]?.AsInteger, e["serverTime"]?.AsInteger);
    }
    catch (CloudFailure) { }
    return new(null, null, null, null);
  }

  // ---- Feed ----

  /// POST /changes: one signed pack. The request id is the descriptor's own (feed.ts checks they match).
  public async Task<CloudCommitReceipt> CommitAsync(CloudSegmentDescriptor descriptor, byte[] ciphertext, CancellationToken ct)
  {
    if (ciphertext.Length > MaximumSegmentBytes || descriptor.OpCount is < 1 or > 256 || ciphertext.LongLength != descriptor.Bytes
      || CloudBytes.Sha256Hex(ciphertext) != descriptor.Sha256 || descriptor.Format != CloudPackFormat.Name) throw new CloudFailure("invalid_request");
    var o = Object(await CallAsync("POST", "/changes", CloudJson.Obj(("descriptor", descriptor.ToJson()), ("ciphertext", CloudJson.From(CloudBytes.Base64Url(ciphertext)))),
      descriptor.RequestId, packScoped: true, ct));
    var receipt = Object(o["receipt"]);
    var result = new CloudCommitReceipt(Text(o, "segmentId"), Seq(o, "seq"), Seq(o, "headSeq"), Text(receipt, "requestId"), Text(receipt, "sha256"), Integer(receipt, "committedAt"));
    if (result.SegmentId != descriptor.SegmentId || result.Sha256 != descriptor.Sha256 || result.RequestId != descriptor.RequestId || result.Seq == 0) throw new CloudFailure("checksum_mismatch");
    return result;
  }

  /// GET /changes?after=&limit= (limit 1..128).
  public async Task<CloudChangePage> ChangesAsync(ulong after, int limit, CancellationToken ct)
  {
    if (limit is < 1 or > FeedPageLimit) throw new CloudFailure("invalid_request");
    var o = Object(await CallAsync("GET", $"/changes?after={after.ToString(CultureInfo.InvariantCulture)}&limit={limit.ToString(CultureInfo.InvariantCulture)}", null, null, false, ct));
    if (o["segments"] is not CloudJson.Array rows) throw new CloudFailure("invalid_response");
    var page = new CloudChangePage(rows.Items.Select(ParseEntry).ToArray(), Seq(o, "headSeq"), Seq(o, "nextAfter"), o["hasMore"] is CloudJson.Bool { Value: true });
    if (page.HeadSeq < after || page.NextAfter < after || page.NextAfter > page.HeadSeq || page.HasMore && page.Segments.Count == 0) throw new CloudFailure("invalid_response");
    return page;
  }

  public static CloudChangeEntry ParseEntry(CloudJson row)
  {
    var o = row as CloudJson.Object ?? throw new CloudFailure("invalid_response");
    var seq = Seq(o, "seq");
    var storageClass = Text(o, "class");
    var locked = o["locked"] is CloudJson.Bool { Value: true };
    CloudSegmentDescriptor? descriptor = null;
    if (!locked)
    {
      // A missing stated field leaves the descriptor null: the judged loop refuses it as malformed; nothing throws.
      try
      {
        descriptor = new CloudSegmentDescriptor(Text(o, "segmentId"), Text(o, "requestId"), storageClass, Text(o, "purpose"),
          (o["domains"] as CloudJson.Array ?? throw new CloudFailure("invalid_request")).Items.Select(d => d.AsString ?? throw new CloudFailure("invalid_request")).ToArray(),
          (int)Integer(o, "keyEpoch"), Text(o, "sha256"), Integer(o, "bytes"), (int)Integer(o, "opCount"), Text(o, "format"), Text(o, "signature"));
      }
      catch (CloudFailure) { descriptor = null; }
    }
    Uri? url = o["getUrl"]?.AsString is { } u && Uri.TryCreate(u, UriKind.Absolute, out var parsed) ? parsed : null;
    return new(seq, storageClass, locked, o["deviceId"]?.AsString, o["createdAt"]?.AsInteger, url, o["expiresAt"]?.AsInteger, descriptor,
      o["segmentId"]?.AsString, o["sha256"]?.AsString, o["bytes"]?.AsInteger);
  }

  /// POST /applied: this PC's applied positions (advisory on the service).
  public async Task AppliedAsync(ulong brainSeq, ulong secretsSeq, string? checkpointId, CancellationToken ct)
  {
    var o = Object(await CallAsync("POST", "/applied", CloudJson.Obj(("brainSeq", SeqJson(brainSeq)), ("secretsSeq", SeqJson(secretsSeq)),
      ("checkpointId", checkpointId is null ? null : CloudJson.From(checkpointId))), null, false, ct));
    if (Seq(o, "brainSeq") < brainSeq || Seq(o, "secretsSeq") < secretsSeq) throw new CloudFailure("checksum_mismatch");
  }

  /// GET /checkpoints/current: only its id and position are used (a first upload is passed over, never imported).
  public async Task<CloudCurrentCheckpoint?> CheckpointAsync(CancellationToken ct)
  {
    var o = Object(await CallAsync("GET", "/checkpoints/current", null, null, false, ct));
    return o["checkpoint"] is CloudJson.Object c ? new(Text(c, "checkpointId"), Seq(c, "throughSeq")) : null;
  }

  /// POST /brain-key: the account's memory key for an epoch. Internal plumbing only: never a tool, never logged.
  public async Task<(int Epoch, byte[] Key)> BrainKeyAsync(int? epoch, CancellationToken ct)
  {
    if (epoch is <= 0) throw new CloudFailure("invalid_request");
    var o = Object(await CallAsync("POST", "/brain-key", CloudJson.Obj(("epoch", epoch is { } e ? CloudJson.From(e) : null)), CloudBytes.NewTransportId(), false, ct));
    var answered = (int)Integer(o, "epoch");
    var key = CloudBytes.Unbase64(Text(o, "key"));
    if (answered <= 0 || epoch is { } wanted && wanted != answered || key.Length != 32) { CryptographicOperations.ZeroMemory(key); throw new CloudFailure("checksum_mismatch"); }
    return (answered, key);
  }

  // ---- Blobs (blobs.ts): prepare, upload with the grant, finalize, read, download ----

  public async Task<IReadOnlyList<CloudBlobTicket>> PrepareBlobsAsync(IReadOnlyList<CloudBlobUpload> items, CancellationToken ct)
  {
    if (items.Count is < 1 or > 16) throw new CloudFailure("invalid_request");
    var renew = items.Any(i => metadata.Get("refresh-upload:" + i.UploadId) == "1");
    var tickets = await Prepare(items, renew, ct);
    if (tickets.Any(t => !t.AlreadyPresent && t.ExpiresAt <= ServiceNow())) tickets = await Prepare(items, true, ct);
    if (tickets.Count != items.Count || tickets.Any(t => !t.AlreadyPresent && t.ExpiresAt <= ServiceNow())) throw new CloudFailure("invalid_response");
    foreach (var item in items)
    {
      metadata.Set("refresh-upload:" + item.UploadId, null);
      metadata.Set("prepared-upload:" + item.UploadId, Encoding.UTF8.GetString(CloudCanonical.Encode(item.ToJson())));
    }
    return tickets;
  }
  private async Task<IReadOnlyList<CloudBlobTicket>> Prepare(IReadOnlyList<CloudBlobUpload> items, bool fresh, CancellationToken ct)
  {
    var o = Object(await CallAsync("POST", "/blobs/prepare", CloudJson.Obj(("items", CloudJson.Arr(items.Select(i => i.ToJson())))), null, false, ct, fresh));
    return Items(o).Select(i => new CloudBlobTicket(Text(i, "uploadId"), Text(i, "blobId"),
      i["putUrl"]?.AsString is { } u ? new Uri(u) : null,
      i["headers"] is CloudJson.Object h ? h.Members.ToDictionary(m => m.Key, m => m.Value.AsString ?? throw new CloudFailure("invalid_response"), StringComparer.OrdinalIgnoreCase) : new Dictionary<string, string>(),
      Text(i, "ticket"), Integer(i, "expiresAt"), i["alreadyPresent"] is CloudJson.Bool { Value: true })).ToArray();
  }

  public async Task<IReadOnlyList<CloudBlobResult>> FinalizeBlobsAsync(IReadOnlyList<(string UploadId, string BlobId, string Ticket)> items, CancellationToken ct)
  {
    if (items.Count is < 1 or > 16) throw new CloudFailure("invalid_request");
    var o = Object(await CallAsync("POST", "/blobs/finalize", CloudJson.Obj(("items", CloudJson.Arr(items.Select(i =>
      (CloudJson)CloudJson.Obj(("uploadId", CloudJson.From(i.UploadId)), ("blobId", CloudJson.From(i.BlobId)), ("ticket", CloudJson.From(i.Ticket))))))), null, false, ct));
    var results = Items(o).Select(i => new CloudBlobResult(Text(i, "uploadId"), i["blob"] is CloudJson.Object b ? b : null,
      (i["error"] as CloudJson.Object)?["code"]?.AsString, (i["error"] as CloudJson.Object)?["retryable"] is CloudJson.Bool { Value: true })).ToArray();
    if (results.Length != items.Count || results.Any(r => (r.Blob is null) == (r.ErrorCode is null))) throw new CloudFailure("invalid_response");
    return results;
  }

  public async Task<IReadOnlyList<CloudBlobDownload>> ReadBlobsAsync(IReadOnlyList<string> blobIds, CancellationToken ct)
  {
    if (blobIds.Count is < 1 or > 16) throw new CloudFailure("invalid_request");
    var o = Object(await CallAsync("POST", "/blobs/read", CloudJson.Obj(("blobIds", CloudJson.Arr(blobIds.Select(b => CloudJson.From(b))))), CloudBytes.NewTransportId(), false, ct));
    var downloads = Items(o).Select(i => { var blob = Object(i["blob"]); return new CloudBlobDownload(blob, Text(blob, "blobId"), new Uri(Text(i, "getUrl")), Integer(i, "expiresAt")); }).ToArray();
    if (downloads.Length != blobIds.Count || !downloads.Select(d => d.BlobId).ToHashSet().SetEquals(blobIds)) throw new CloudFailure("invalid_response");
    return downloads;
  }

  /// PUT to the granted link. Only the grant's content headers are used; the bytes must be exactly what was prepared.
  /// An expired or vanished grant marks the upload for a fresh prepare and throws `upload_expired`.
  public async Task UploadAsync(byte[] bytes, CloudBlobTicket ticket, CancellationToken ct)
  {
    if (ticket.PutUrl is not { } url || bytes.Length > CloudPackFormat.MaximumBlobBytes) throw new CloudFailure("unavailable");
    if (ticket.ExpiresAt <= ServiceNow()) { metadata.Set("refresh-upload:" + ticket.UploadId, "1"); throw new CloudFailure("upload_expired"); }
    endpoint.PermitObject(url);
    var prepared = metadata.Get("prepared-upload:" + ticket.UploadId) is { } saved ? CloudJson.Parse(saved) as CloudJson.Object : null;
    var md5 = Convert.ToBase64String(MD5.HashData(bytes));
    if (prepared is null || Text(prepared, "blobId") != ticket.BlobId || Integer(prepared, "bytes") != bytes.Length || Text(prepared, "sha256") != CloudBytes.Sha256Hex(bytes)
      || Text(prepared, "md5") != md5) throw new CloudFailure("checksum_mismatch");
    var headers = await TransferHeadersAsync("PUT", url, bytes, ct);
    foreach (var (name, value) in ticket.Headers)
    {
      if (name.ToLowerInvariant() is not ("content-type" or "content-md5")) throw new CloudFailure("unsafe_configuration");
      headers[name] = value;
    }
    if (!headers.TryGetValue("Content-Type", out var type) || type != "application/octet-stream" || !headers.TryGetValue("Content-MD5", out var sent) || sent != md5)
      throw new CloudFailure("checksum_mismatch");
    var response = await Guard(() => http.SendAsync(new("PUT", url, headers, bytes, MaximumControlBytes), ct), ct);
    if (response.Status is >= 200 and < 300) { Backoff.Succeeded(); return; }
    if (ErrorDetail(response.Body).Code is { } code && CloudRefusal.ProtectedOnlyCodes.Contains(code)) throw new CloudFailure(code, response.Status);
    if (response.Status == 404) { metadata.Set("refresh-upload:" + ticket.UploadId, "1"); throw new CloudFailure("upload_expired", 404); }
    var failure = new CloudFailure("unavailable", response.Status, response.Status >= 500);
    Backoff.Failed(failure);
    throw failure;
  }

  /// GET a granted link (feed packs and blobs). A link that expired (404) throws `read_expired`: the caller renews it.
  public async Task<byte[]> DownloadAsync(Uri url, int maximumBytes, CancellationToken ct)
  {
    if (maximumBytes <= 0 || maximumBytes > CloudPackFormat.MaximumBlobBytes) throw new CloudFailure("unavailable");
    endpoint.PermitObject(url);
    var headers = await TransferHeadersAsync("GET", url, [], ct);
    var response = await Guard(() => http.SendAsync(new("GET", url, headers, [], maximumBytes), ct), ct);
    if (response.Status == 200)
    {
      if (response.Body.Length > maximumBytes) throw new CloudFailure("checksum_mismatch");
      Backoff.Succeeded();
      return response.Body;
    }
    if (response.Status == 404) throw new CloudFailure("read_expired", 404);
    var failure = new CloudFailure("unavailable", response.Status, response.Status >= 500);
    Backoff.Failed(failure);
    throw failure;
  }

  /// Transfer proofs are single use: a fresh id and time every attempt, the content hash in X-TD-Content-SHA256.
  private async Task<Dictionary<string, string>> TransferHeadersAsync(string method, Uri url, byte[] bytes, CancellationToken ct)
  {
    var credentials = await Guard(() => auth.CredentialsAsync(ct), ct);
    if (credentials.UserId != subject) throw new CloudFailure("unsafe_configuration");
    var time = ServiceNow();
    if (credentials.ExpiresAt <= time) throw new CloudFailure("unavailable");
    var id = CloudBytes.NewTransportId();
    var proof = auth.Proof(method, url.AbsolutePath + url.Query, bytes, time, id);
    if (!proof.TryGetValue("X-TD-Device", out var device) || device != credentials.DeviceId) throw new CloudFailure("invalid_request");
    return new Dictionary<string, string>(proof, StringComparer.OrdinalIgnoreCase)
    {
      ["Authorization"] = "Bearer " + credentials.AccessToken, ["Cache-Control"] = "no-store", ["X-TD-Content-SHA256"] = CloudBytes.Sha256Hex(bytes)
    };
  }

  // ---- Events ----

  /// Listens until `ct` ends or the gate closes. `hello` and `changed` are hints only: the engine always catches up
  /// from its own position. A dropped connection waits by the socket's own streak (doubling from 1 s, capped at 60 s)
  /// and never feeds the shared back-off; only the service's stated refusals do.
  public async Task ListenAsync(ICloudSyncSocketFactory sockets, Func<CloudSyncEvent, Task> onEvent, CancellationToken ct, Func<TimeSpan, CancellationToken, Task>? delay = null)
  {
    delay ??= Task.Delay;
    var streak = 0;
    while (!ct.IsCancellationRequested)
    {
      long connectedAt = 0;
      try
      {
        var credentials = await auth.CredentialsAsync(ct);
        if (credentials.UserId != subject) throw new CloudFailure("unsafe_configuration");
        var requestId = CloudBytes.NewTransportId();
        var headers = new Dictionary<string, string>(auth.Proof("GET", "/v1/events", [], ServiceNow(), requestId), StringComparer.OrdinalIgnoreCase)
        { ["Authorization"] = "Bearer " + credentials.AccessToken, ["Cache-Control"] = "no-store" };
        var url = new UriBuilder(endpoint.Control("/events")) { Scheme = "wss" }.Uri;
        await using var socket = await sockets.ConnectAsync(url, headers, ct);
        using var heartbeat = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _ = Task.Run(async () =>
        {
          try { while (!heartbeat.IsCancellationRequested) { await delay(TimeSpan.FromSeconds(25), heartbeat.Token); await socket.SendAsync("td-ping", heartbeat.Token); } }
          catch (Exception) { }
        }, CancellationToken.None);
        try
        {
          while (!ct.IsCancellationRequested)
          {
            var frame = await socket.ReceiveAsync(ct);
            if (frame is null) break;
            if (frame == "td-pong") continue;
            if (Encoding.UTF8.GetByteCount(frame) > MaximumControlBytes) throw new CloudFailure("invalid_request");
            var o = CloudJson.Parse(frame) as CloudJson.Object ?? throw new CloudFailure("invalid_request");
            // Unknown members are ignored (the Mac's lesson, 14 Nov: a decoder that refuses new fields drops the socket
            // for good once the service adds one); only the version must be the one this PC reads.
            if (o["v"]?.AsInteger != 1) throw new CloudFailure("unsupported_format");
            var evt = new CloudSyncEvent(Text(o, "type"), Text(o, "id"), o["payload"] ?? CloudJson.Obj());
            if (evt.Type == "gate") { await onEvent(evt); Backoff.Failed(new CloudFailure("gate_closed", 403)); return; }
            if (evt.Type == "error")
            {
              var e = evt.Payload as CloudJson.Object;
              var failure = new CloudFailure(e?["code"]?.AsString ?? "unavailable", 0, e?["retryable"] is CloudJson.Bool { Value: true });
              if (failure.Code == "device_revoked") { Backoff.Failed(new CloudFailure("device_revoked", 403)); return; }
              throw failure;
            }
            if (evt.Type == "hello" && connectedAt == 0) connectedAt = clock();
            await onEvent(evt);
          }
        }
        finally { await heartbeat.CancelAsync(); }
      }
      catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
      catch (Exception error)
      {
        var kind = CloudRefusal.Classify(error);
        if (kind is CloudRefusalKind.Account or CloudRefusalKind.Gate or CloudRefusalKind.Budget or CloudRefusalKind.Remote) { Backoff.Failed(error); if (kind != CloudRefusalKind.Budget) return; }
      }
      if (ct.IsCancellationRequested) return;
      var stable = connectedAt > 0 && clock() - connectedAt >= 60_000;
      streak = stable ? 1 : Math.Min(streak + 1, 1000);
      var wait = Math.Max(SocketBackoff(streak), Backoff.RetryAt - clock());
      try { await delay(TimeSpan.FromMilliseconds(wait), ct); } catch (OperationCanceledException) { return; }
    }
  }
  public static long SocketBackoff(int streak, long baseMs = 1000) => Math.Min(60_000, baseMs << Math.Min(Math.Max(streak - 1, 0), 20)) + Random.Shared.NextInt64(0, baseMs / 2 + 1);

  // ---- Small typed reads ----
  private static CloudJson.Object Object(CloudJson? value) => value as CloudJson.Object ?? throw new CloudFailure("invalid_response");
  private static IEnumerable<CloudJson.Object> Items(CloudJson.Object o) =>
    (o["items"] as CloudJson.Array ?? throw new CloudFailure("invalid_response")).Items.Select(Object);
  private static string Text(CloudJson.Object o, string key) => o[key]?.AsString ?? throw new CloudFailure("invalid_response");
  private static long Integer(CloudJson.Object o, string key) => o[key]?.AsInteger ?? throw new CloudFailure("invalid_response");
  /// A feed position as the service writes it: decimal text, no leading zero.
  public static ulong Seq(CloudJson.Object o, string key)
  {
    var text = o[key]?.AsString ?? throw new CloudFailure("invalid_response");
    if (text.Length == 0 || !text.All(char.IsAsciiDigit) || text.Length > 1 && text[0] == '0' || !ulong.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var v))
      throw new CloudFailure("invalid_response");
    return v;
  }
  public static CloudJson SeqJson(ulong seq) => CloudJson.From(seq.ToString(CultureInfo.InvariantCulture));
}

/// Production HTTP for sync: HTTPS only, no redirects, no cookies, bounded answers, content headers placed on content.
public sealed class HttpClientCloudSyncHttp : ICloudSyncHttp, IDisposable
{
  private readonly HttpClient client = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false, MaxConnectionsPerServer = 2 }) { Timeout = TimeSpan.FromSeconds(60) };
  public async Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken ct)
  {
    if (request.Url.Scheme != "https") throw new CloudFailure("unsafe_configuration");
    using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.Url);
    if (request.Method != "GET")
    {
      message.Content = new ByteArrayContent(request.Body);
      message.Content.Headers.ContentLength = request.Body.Length;
    }
    foreach (var (name, value) in request.Headers)
    {
      if (name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) { if (message.Content is not null) message.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(value); }
      else if (name.Equals("Content-MD5", StringComparison.OrdinalIgnoreCase)) { if (message.Content is not null) message.Content.Headers.ContentMD5 = Convert.FromBase64String(value); }
      else message.Headers.TryAddWithoutValidation(name, value);
    }
    using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, ct);
    if (response.Content.Headers.ContentLength > request.MaximumAnswerBytes) throw new CloudFailure("checksum_mismatch");
    await using var stream = await response.Content.ReadAsStreamAsync(ct);
    var buffer = new MemoryStream(); var chunk = new byte[16_384]; int read;
    while ((read = await stream.ReadAsync(chunk, ct)) > 0)
    {
      if (buffer.Length + read > request.MaximumAnswerBytes) throw new CloudFailure("checksum_mismatch");
      buffer.Write(chunk, 0, read);
    }
    long? retryAfter = response.Headers.RetryAfter?.Delta is { } d ? (long)d.TotalSeconds : null;
    return new((int)response.StatusCode, buffer.ToArray(), retryAfter);
  }
  public void Dispose() => client.Dispose();
}

/// Production event socket over ClientWebSocket. Text frames only, bounded.
public sealed class ClientWebSocketCloudSyncSockets : ICloudSyncSocketFactory
{
  public async Task<ICloudSyncSocket> ConnectAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
  {
    if (url.Scheme != "wss") throw new CloudFailure("unsafe_configuration");
    var socket = new ClientWebSocket();
    foreach (var (name, value) in headers) socket.Options.SetRequestHeader(name, value);
    await socket.ConnectAsync(url, ct);
    return new Socket(socket);
  }
  private sealed class Socket(ClientWebSocket socket) : ICloudSyncSocket
  {
    public async Task<string?> ReceiveAsync(CancellationToken ct)
    {
      var buffer = new byte[16_384]; using var frame = new MemoryStream();
      while (true)
      {
        var result = await socket.ReceiveAsync(buffer, ct);
        if (result.MessageType == WebSocketMessageType.Close) return null;
        if (frame.Length + result.Count > CloudFeedClient.MaximumControlBytes) throw new CloudFailure("invalid_request");
        frame.Write(buffer, 0, result.Count);
        if (result.EndOfMessage) return Encoding.UTF8.GetString(frame.ToArray());
      }
    }
    public Task SendAsync(string text, CancellationToken ct) => socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, ct);
    public async ValueTask DisposeAsync()
    {
      try { if (socket.State == WebSocketState.Open) await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); } catch (Exception) { }
      socket.Dispose();
    }
  }
}
