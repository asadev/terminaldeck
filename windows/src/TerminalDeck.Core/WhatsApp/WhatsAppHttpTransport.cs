using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.WhatsApp;

/// The real IWhatsAppTransport: HttpClient against WhatsApp's Agent Platform (https://api.whatsapp.com/agent/v1),
/// following the manual's own rules (version 1, 25 Aug 2026). A port of the Mac's WhatsAppHTTPTransport.swift.
///
/// What it guarantees, per key:
/// - never two polls at once; sends and status calls strictly one after another (one lane each, first come first served);
/// - at most 12 sends, 12 status calls, 15 polls and 12 media requests in any 60 seconds (rolling window);
/// - a 2xx send is never retried; a 4xx is not retried except 429; a 503 with code 131016 is retried after backing off;
///   a 500, a 503 with another code, or a lost connection after the request left is reported as "unknown whether sent"
///   (Failed(UnknownWhetherSent)) and NOT retried, so a message is never sent twice;
/// - the key is only ever placed in the Authorization header. No log line, error text, outcome or ToString() holds it.
public sealed class WhatsAppHttpTransport : IWhatsAppTransport, IDisposable
{
  public static readonly Uri DefaultBase = new("https://api.whatsapp.com/agent/v1");

  /// The Failed text when WhatsApp's answer was lost after the request left (500, a timeout, a dropped connection).
  /// The engine can compare against it; the message is not sent again.
  public const string UnknownWhetherSent = "WhatsApp did not say whether the message arrived, so it was not sent again.";

  /// Where a media url may point; the key is sent with the download, so nowhere else.
  public static readonly IReadOnlyList<string> DefaultMediaHosts = ["whatsapp.com", "whatsapp.net", "fbsbx.com", "facebook.com", "fbcdn.net"];

  /// The numbers the manual gives, and the client's own timing. Tests may shrink them.
  public sealed record Limits
  {
    public int SendsPerMinute { get; init; } = WhatsAppLimits.SendsPerMinute;
    public int StatusesPerMinute { get; init; } = WhatsAppLimits.StatusesPerMinute;
    public int PollsPerMinute { get; init; } = WhatsAppLimits.PollsPerMinute;
    public int MediaPerMinute { get; init; } = WhatsAppLimits.MediaPerMinute;
    /// First back-off wait; it doubles on every failure in a row, capped at LongestBackOff.
    public double FirstBackOff { get; init; } = 2;
    public double LongestBackOff { get; init; } = WhatsAppLimits.BackOffCapSeconds;
    /// Tries for one send that keeps meeting 429 / 503 131016 / no connection before BackOff is returned.
    public int SendAttempts { get; init; } = 3;
    /// Tries for one status call (marking read is harmless to repeat).
    public int StatusAttempts { get; init; } = 2;
    /// The client's own read timeout for a send, status or check call: well above the time a send needs.
    public double CallTimeout { get; init; } = 60;
    /// Added to the long-poll's own timeout for the client's read timeout (25 s poll -> 60 s).
    public double PollGrace { get; init; } = 35;
    /// The download of one media item.
    public double MediaTimeout { get; init; } = 120;
    /// The largest media item the manual allows (video, audio, document): 16 MB.
    public long LargestMedia { get; init; } = WhatsAppLimits.OtherMediaBytes;
  }

  private enum Lane { Poll, Out, Media }
  private enum Window { Poll, Send, Status, Media }

  private static readonly JsonSerializerOptions Json = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

  private readonly HttpClient http;
  private readonly Uri baseUri;
  private readonly IWhatsAppClock clock;
  private readonly Limits limits;
  private readonly IReadOnlyList<string> mediaHosts;
  private readonly object gate = new();
  private readonly Dictionary<(string Agent, Lane Lane), FifoLock> lanes = new();
  private readonly Dictionary<(string Agent, Window Window), List<DateTimeOffset>> calls = new();
  private readonly Dictionary<(string Agent, Window Window), double> backOff = new();

  public WhatsAppHttpTransport(HttpMessageHandler? handler = null, Uri? baseUri = null, IWhatsAppClock? clock = null,
    Limits? limits = null, IReadOnlyList<string>? mediaHosts = null)
  {
    http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
    http.Timeout = Timeout.InfiniteTimeSpan;
    var b = (baseUri ?? DefaultBase).AbsoluteUri;
    this.baseUri = new Uri(b.EndsWith('/') ? b : b + "/");
    this.clock = clock ?? WhatsAppSystemClock.Shared;
    this.limits = limits ?? new Limits();
    this.mediaHosts = mediaHosts ?? DefaultMediaHosts;
  }

  public void Dispose() => http.Dispose();
  public override string ToString() => nameof(WhatsAppHttpTransport);

  // ---- the protocol --------------------------------------------------------------------------------------

  public async Task<WhatsAppKeyCheck> CheckAsync(string key, CancellationToken cancellationToken = default)
  {
    if (!HeaderSafe(key)) return WhatsAppKeyCheck.Refused;
    var agent = Agent(key);
    using var held = await LaneOf(agent, Lane.Poll).EnterAsync(cancellationToken).ConfigureAwait(false);
    await WaitForRoomAsync(agent, Window.Poll, cancellationToken).ConfigureAwait(false);
    var outcome = await PerformAsync(key, HttpMethod.Get, "updates?limit=1&timeout=0", null, limits.CallTimeout, cancellationToken).ConfigureAwait(false);
    if (outcome.Status is not int status) return WhatsAppKeyCheck.Unreachable;
    return status switch
    {
      200 or 204 or 409 => WhatsAppKeyCheck.Accepted,
      401 => WhatsAppKeyCheck.Refused,
      400 => ErrorCode(outcome.Body) == 100 ? WhatsAppKeyCheck.Refused : WhatsAppKeyCheck.Unreachable,
      _ => WhatsAppKeyCheck.Unreachable,
    };
  }

  public async Task<WhatsAppPoll> PollAsync(string key, long? offset, int timeout, CancellationToken cancellationToken = default)
  {
    if (!HeaderSafe(key)) return WhatsAppPoll.Refused;
    var agent = Agent(key);
    using var held = await LaneOf(agent, Lane.Poll).EnterAsync(cancellationToken).ConfigureAwait(false);
    await WaitForRoomAsync(agent, Window.Poll, cancellationToken).ConfigureAwait(false);
    var wait = Math.Clamp(timeout, 0, WhatsAppLimits.PollTimeoutMaxSeconds);
    var query = new StringBuilder("updates?");
    if (offset is long o) query.Append("offset=").Append(Math.Max(o, 0).ToString(CultureInfo.InvariantCulture)).Append('&');
    query.Append("limit=").Append(WhatsAppLimits.PollBatch.ToString(CultureInfo.InvariantCulture))
      .Append("&timeout=").Append(wait.ToString(CultureInfo.InvariantCulture));
    var outcome = await PerformAsync(key, HttpMethod.Get, query.ToString(), null, wait + limits.PollGrace, cancellationToken).ConfigureAwait(false);
    var id = (agent, Window.Poll);
    switch (outcome.Status)
    {
      case 200:
        if (!WhatsAppUpdates.TryParse(outcome.Body, out var messages, out var next)) return new WhatsAppPoll.BackOff(Grow(id));
        Reset(id);
        return new WhatsAppPoll.Messages(messages, next);
      case 204: Reset(id); return WhatsAppPoll.NothingNew;
      case 409: Reset(id); return WhatsAppPoll.ReplacedByNewer;
      case 401: return WhatsAppPoll.Refused;
      case 400 when ErrorCode(outcome.Body) == 100: return WhatsAppPoll.Refused;
      default:
        // 429, 5xx, a malformed query or no connection: reuse the same offset after waiting.
        return new WhatsAppPoll.BackOff(Grow(id));
    }
  }

  public async Task<WhatsAppSent> MarkReadAsync(string key, string messageId, bool typing, CancellationToken cancellationToken = default)
  {
    if (!HeaderSafe(key)) return WhatsAppSent.Refused;
    var agent = Agent(key);
    using var held = await LaneOf(agent, Lane.Out).EnterAsync(cancellationToken).ConfigureAwait(false);
    var body = new JsonObject { ["messaging_product"] = "whatsapp", ["status"] = "read", ["message_id"] = messageId };
    if (typing) body["typing_indicator"] = new JsonObject { ["type"] = "text" };
    var payload = body.ToJsonString(Json);
    var id = (agent, Window.Status);
    for (var attempt = 1; ; attempt++)
    {
      // A read mark or a typing refresh that would wait for room is skipped, not queued behind the answer.
      if (TakeRoom(agent, Window.Status) is double full) return new WhatsAppSent.BackOff(full);
      var outcome = await PerformAsync(key, HttpMethod.Post, "statuses", payload, limits.CallTimeout, cancellationToken).ConfigureAwait(false);
      switch (outcome.Status)
      {
        case int s when s is >= 200 and < 300: Reset(id); return WhatsAppSent.Done;
        case 401: return WhatsAppSent.Refused;
        case 403: return WhatsAppSent.NotTheCreator;
        case 400:
          var code = ErrorCode(outcome.Body);
          if (code == 100) return WhatsAppSent.Refused;
          return new WhatsAppSent.Failed("WhatsApp could not mark the message read" + CodeWords(400, code) + ".");
        case int s when s == 429 || s >= 500: break; // not marked (or unknown): marking again is harmless
        case int s: return new WhatsAppSent.Failed("WhatsApp could not mark the message read" + CodeWords(s, ErrorCode(outcome.Body)) + ".");
        case null: break;
      }
      var wait = Grow(id);
      if (attempt >= limits.StatusAttempts) return new WhatsAppSent.BackOff(wait);
      await clock.DelayAsync(TimeSpan.FromSeconds(wait), cancellationToken).ConfigureAwait(false);
    }
  }

  public async Task<WhatsAppSent> SendAsync(string key, string to, string text, CancellationToken cancellationToken = default)
  {
    // Only the creator ("user:<id>", copied from an inbound From) can be addressed; anything else never leaves.
    if (to is null || !to.StartsWith("user:", StringComparison.Ordinal) || to.Length <= "user:".Length) return WhatsAppSent.NotTheCreator;
    if (string.IsNullOrEmpty(text)) return new WhatsAppSent.Failed("There was nothing to send.");
    if (text.Length > WhatsAppText.Limit) return new WhatsAppSent.Failed($"The message is longer than WhatsApp allows ({WhatsAppText.Limit} characters).");
    if (!HeaderSafe(key)) return WhatsAppSent.Refused;
    var agent = Agent(key);
    using var held = await LaneOf(agent, Lane.Out).EnterAsync(cancellationToken).ConfigureAwait(false);
    var payload = new JsonObject
    {
      ["messaging_product"] = "whatsapp", ["to"] = to, ["type"] = "text", ["text"] = new JsonObject { ["body"] = text },
    }.ToJsonString(Json);
    var id = (agent, Window.Send);
    for (var attempt = 1; ; attempt++)
    {
      await WaitForRoomAsync(agent, Window.Send, cancellationToken).ConfigureAwait(false);
      var outcome = await PerformAsync(key, HttpMethod.Post, "messages", payload, limits.CallTimeout, cancellationToken).ConfigureAwait(false);
      switch (outcome.Status)
      {
        case int s when s is >= 200 and < 300: Reset(id); return WhatsAppSent.Done; // sent: never retried
        case 429: break;                                                              // not sent: retry after backing off
        case 503 when ErrorCode(outcome.Body) == 131016: break;                      // not accepted for delivery: not sent
        case int s when s >= 500: return new WhatsAppSent.Failed(UnknownWhetherSent); // it may or may not have been sent
        case 401: return WhatsAppSent.Refused;
        case 403: return WhatsAppSent.NotTheCreator;
        case 400:
          var code = ErrorCode(outcome.Body);
          // Code 100 is also a length cap; then the message names the field instead of a sentence.
          if (code == 100) return IsLengthCap(outcome.Body) ? new WhatsAppSent.Failed("WhatsApp said the message is too long.") : WhatsAppSent.Refused;
          return new WhatsAppSent.Failed("WhatsApp refused the message" + CodeWords(400, code) + ".");
        case int s: return new WhatsAppSent.Failed("WhatsApp refused the message" + CodeWords(s, ErrorCode(outcome.Body)) + ".");
        case null when outcome.Failure == Failure.Unknown: return new WhatsAppSent.Failed(UnknownWhetherSent);
        case null: break; // the request never left this computer: safe to try again
      }
      var wait = Grow(id);
      if (attempt >= limits.SendAttempts) return new WhatsAppSent.BackOff(wait);
      await clock.DelayAsync(TimeSpan.FromSeconds(wait), cancellationToken).ConfigureAwait(false);
    }
  }

  public async Task<WhatsAppMedia?> MediaAsync(string key, string id, long limit, CancellationToken cancellationToken = default)
  {
    var most = Math.Min(limit, limits.LargestMedia);
    if (most <= 0 || string.IsNullOrEmpty(id) || !HeaderSafe(key)) return null;
    // Media ids are opaque handles of letters, digits and dashes; anything else is not WhatsApp's and is not asked for.
    if (id.StartsWith('.') || !id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.')) return null;
    var agent = Agent(key);
    using var held = await LaneOf(agent, Lane.Media).EnterAsync(cancellationToken).ConfigureAwait(false);
    await WaitForRoomAsync(agent, Window.Media, cancellationToken).ConfigureAwait(false);
    var meta = await PerformAsync(key, HttpMethod.Get, "media/" + id, null, limits.CallTimeout, cancellationToken).ConfigureAwait(false);
    if (meta.Status != 200) return null;
    string? link, mime; long? size;
    try
    {
      using var doc = JsonDocument.Parse(meta.Body);
      if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
      link = Str(doc.RootElement, "url");
      mime = Str(doc.RootElement, "mime_type");
      size = doc.RootElement.TryGetProperty("file_size", out var s) && WhatsAppUpdates.TryInt64(s, out var n) ? n : null;
    }
    catch (JsonException) { return null; }
    if (link is null || !Uri.TryCreate(link, UriKind.Absolute, out var url) || !IsAllowedMediaUrl(url)) return null;
    if (size > most) return null;
    await WaitForRoomAsync(agent, Window.Media, cancellationToken).ConfigureAwait(false);
    var bytes = await DownloadAsync(key, url, most, cancellationToken).ConfigureAwait(false);
    if (bytes is null || bytes.Length == 0) return null;
    return new WhatsAppMedia(bytes, string.IsNullOrEmpty(mime) ? "application/octet-stream" : mime);
  }

  // ---- lanes, rate windows and back-off -------------------------------------------------------------------

  /// One call at a time per key and lane, first come first served.
  private sealed class FifoLock
  {
    private readonly object gate = new();
    private readonly LinkedList<TaskCompletionSource<bool>> waiting = new();
    private bool busy;

    public async Task<IDisposable> EnterAsync(CancellationToken cancellationToken)
    {
      TaskCompletionSource<bool> turn;
      LinkedListNode<TaskCompletionSource<bool>> node;
      lock (gate)
      {
        if (!busy) { busy = true; return new Exit(this); }
        turn = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        node = waiting.AddLast(turn);
      }
      using (cancellationToken.Register(() =>
      {
        lock (gate) { if (node.List is null) return; waiting.Remove(node); }
        turn.TrySetCanceled(cancellationToken);
      }))
      {
        await turn.Task.ConfigureAwait(false);
      }
      return new Exit(this);
    }

    /// Hands the lane straight to the next waiter (it stays busy) or frees it.
    private void Release()
    {
      TaskCompletionSource<bool>? next = null;
      lock (gate)
      {
        if (waiting.First is { } first) { waiting.RemoveFirst(); next = first.Value; }
        else busy = false;
      }
      next?.TrySetResult(true);
    }

    private sealed class Exit(FifoLock owner) : IDisposable
    {
      private int done;
      public void Dispose() { if (Interlocked.Exchange(ref done, 1) == 0) owner.Release(); }
    }
  }

  private FifoLock LaneOf(string agent, Lane lane)
  {
    lock (gate)
    {
      if (!lanes.TryGetValue((agent, lane), out var l)) lanes[(agent, lane)] = l = new FifoLock();
      return l;
    }
  }

  private int Most(Window window) => window switch
  {
    Window.Poll => limits.PollsPerMinute,
    Window.Send => limits.SendsPerMinute,
    Window.Status => limits.StatusesPerMinute,
    _ => limits.MediaPerMinute,
  };

  /// Records a call if there is room now; otherwise the seconds until there is.
  private double? TakeRoom(string agent, Window window)
  {
    var now = clock.Now;
    lock (gate)
    {
      if (!calls.TryGetValue((agent, window), out var list)) calls[(agent, window)] = list = [];
      list.RemoveAll(t => (now - t).TotalSeconds >= 60);
      if (list.Count < Most(window)) { list.Add(now); return null; }
      return Math.Max(60 - (now - list[0]).TotalSeconds, 0.001);
    }
  }

  private async Task WaitForRoomAsync(string agent, Window window, CancellationToken cancellationToken)
  {
    while (TakeRoom(agent, window) is double wait) await clock.DelayAsync(TimeSpan.FromSeconds(wait), cancellationToken).ConfigureAwait(false);
  }

  /// The next back-off wait for this key and method: first, then doubled each time, capped.
  private double Grow((string, Window) id)
  {
    lock (gate)
    {
      var next = backOff.TryGetValue(id, out var last) ? Math.Min(last * 2, limits.LongestBackOff) : Math.Min(limits.FirstBackOff, limits.LongestBackOff);
      backOff[id] = next;
      return next;
    }
  }

  private void Reset((string, Window) id) { lock (gate) backOff.Remove(id); }

  // ---- HTTP -----------------------------------------------------------------------------------------------

  private enum Failure
  {
    /// The request never left this computer (no network, no such host, could not connect, TLS refused).
    NotSent,
    /// It may have reached WhatsApp (timeout, dropped connection, anything else).
    Unknown,
  }

  private readonly record struct Outcome(int? Status, string Body, Failure? Failure);

  private async Task<Outcome> PerformAsync(string key, HttpMethod method, string path, string? json, double timeoutSeconds, CancellationToken cancellationToken)
  {
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
    try
    {
      using var request = Request(key, method, new Uri(baseUri, path), json);
      using var response = await http.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token).ConfigureAwait(false);
      var body = await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
      return new((int)response.StatusCode, body, null);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return new(null, "", Failure.Unknown); }
    catch (HttpRequestException e) { return new(null, "", NeverLeft(e) ? Failure.NotSent : Failure.Unknown); }
    catch (IOException) { return new(null, "", Failure.Unknown); }
  }

  private static bool NeverLeft(HttpRequestException e) => e.HttpRequestError is
    HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError or HttpRequestError.SecureConnectionError or HttpRequestError.ProxyTunnelError;

  private async Task<byte[]?> DownloadAsync(string key, Uri url, long most, CancellationToken cancellationToken)
  {
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(TimeSpan.FromSeconds(limits.MediaTimeout));
    try
    {
      using var request = Request(key, HttpMethod.Get, url, null);
      using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
      if ((int)response.StatusCode != 200 || response.Content.Headers.ContentLength > most) return null;
      await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
      using var buffer = new MemoryStream();
      var chunk = new byte[81920];
      int read;
      while ((read = await stream.ReadAsync(chunk, timeout.Token).ConfigureAwait(false)) > 0)
      {
        if (buffer.Length + read > most) return null;
        buffer.Write(chunk, 0, read);
      }
      return buffer.ToArray();
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return null; }
    catch (HttpRequestException) { return null; }
    catch (IOException) { return null; }
  }

  private static HttpRequestMessage Request(string key, HttpMethod method, Uri uri, string? json)
  {
    var request = new HttpRequestMessage(method, uri);
    // HeaderSafe was checked: adding the header can never throw (and so never quote) the key.
    request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + key);
    if (json is not null) request.Content = new StringContent(json, Encoding.UTF8, "application/json");
    return request;
  }

  private bool IsAllowedMediaUrl(Uri url)
  {
    if (url.Scheme != Uri.UriSchemeHttps || url.UserInfo.Length > 0) return false;
    var host = url.Host.ToLowerInvariant();
    return mediaHosts.Any(h => host == h || host.EndsWith("." + h, StringComparison.Ordinal));
  }

  /// The key is opaque, but it must be a header-safe token (printable ASCII, no spaces); anything else is refused
  /// here, so it never reaches a header parser that could quote it in an exception.
  private static bool HeaderSafe(string key)
  {
    if (string.IsNullOrEmpty(key) || key.Length > 4096) return false;
    foreach (var ch in key) if (ch <= ' ' || ch > '~') return false;
    return true;
  }

  /// Per-key state is filed under a hash of the key, so no dictionary here holds the key itself.
  private static string Agent(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)));

  // ---- parsing --------------------------------------------------------------------------------------------

  /// error.code of an error body, when there is one.
  internal static long? ErrorCode(string body)
  {
    try
    {
      using var doc = JsonDocument.Parse(body);
      if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object
        && e.TryGetProperty("code", out var c) && WhatsAppUpdates.TryInt64(c, out var code)) return code;
    }
    catch (JsonException) { }
    return null;
  }

  /// A length cap answers code 100 with the field name as the message ("text.body"), not a sentence.
  internal static bool IsLengthCap(string body)
  {
    try
    {
      using var doc = JsonDocument.Parse(body);
      if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("error", out var e) || Str(e, "message") is not { } message) return false;
      var words = message.ToLowerInvariant();
      return words.Contains("body") || words.Contains("caption") || !message.Contains(' ');
    }
    catch (JsonException) { return false; }
  }

  internal static string CodeWords(int status, long? code) =>
    code is long c ? $" (HTTP {status}, code {c.ToString(CultureInfo.InvariantCulture)})" : $" (HTTP {status})";

  internal static string? Str(JsonElement e, string name) =>
    e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}

/// The parse of a 200 from GET /updates (manual section 2). Statuses (receipts) are skipped; a poll of only receipts
/// gives no messages and still the next offset. False = not WhatsApp's shape (treated as a failed poll).
public static class WhatsAppUpdates
{
  public static bool TryParse(string body, out IReadOnlyList<WhatsAppInbound> messages, out long next)
  {
    messages = []; next = 0;
    try
    {
      using var doc = JsonDocument.Parse(body);
      var root = doc.RootElement;
      if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("next_offset", out var n) || !TryInt64(n, out next)) return false;
      var list = new List<WhatsAppInbound>();
      foreach (var entry in Array(root, "entry"))
        foreach (var change in Array(entry, "changes"))
          if (change.ValueKind == JsonValueKind.Object && change.TryGetProperty("value", out var value))
            foreach (var item in Array(value, "messages"))
              if (Inbound(item) is { } m) list.Add(m);
      messages = list;
      return true;
    }
    catch (JsonException) { return false; }
  }

  private static IEnumerable<JsonElement> Array(JsonElement e, string name) =>
    e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var a) && a.ValueKind == JsonValueKind.Array ? a.EnumerateArray() : [];

  public static WhatsAppInbound? Inbound(JsonElement item)
  {
    var id = WhatsAppHttpTransport.Str(item, "id");
    var from = WhatsAppHttpTransport.Str(item, "from");
    if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(from)) return null;
    double seconds = 0;
    if (item.TryGetProperty("timestamp", out var t))
    {
      if (t.ValueKind == JsonValueKind.String && double.TryParse(t.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var ts)) seconds = ts;
      else if (t.ValueKind == JsonValueKind.Number) seconds = t.GetDouble();
    }
    var type = WhatsAppHttpTransport.Str(item, "type") ?? "";
    var kind = type switch
    {
      "text" => WhatsAppInboundKind.Text,
      "image" => WhatsAppInboundKind.Image,
      "audio" => WhatsAppInboundKind.Audio,
      "video" => WhatsAppInboundKind.Video,
      "document" => WhatsAppInboundKind.Document,
      "sticker" => WhatsAppInboundKind.Sticker,
      "reaction" => WhatsAppInboundKind.Reaction,
      _ => WhatsAppInboundKind.Other,
    };
    var payload = type.Length > 0 && item.TryGetProperty(type, out var p) ? p : default;
    var media = kind is WhatsAppInboundKind.Image or WhatsAppInboundKind.Audio or WhatsAppInboundKind.Video or WhatsAppInboundKind.Document or WhatsAppInboundKind.Sticker;
    var when = DateTimeOffset.UnixEpoch.AddTicks((long)(Math.Clamp(seconds, 0, 253402300799) * TimeSpan.TicksPerSecond));
    return new WhatsAppInbound(id, from, when, kind,
      Text: kind == WhatsAppInboundKind.Text ? WhatsAppHttpTransport.Str(payload, "body") : null,
      Caption: WhatsAppHttpTransport.Str(payload, "caption"),
      MediaId: media ? WhatsAppHttpTransport.Str(payload, "id") : null,
      MimeType: media ? WhatsAppHttpTransport.Str(payload, "mime_type") : null,
      FileName: kind == WhatsAppInboundKind.Document ? WhatsAppHttpTransport.Str(payload, "filename") : null);
  }

  internal static bool TryInt64(JsonElement e, out long value)
  {
    value = 0;
    return e.ValueKind switch
    {
      JsonValueKind.Number => e.TryGetInt64(out value),
      JsonValueKind.String => long.TryParse(e.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value),
      _ => false,
    };
  }
}
