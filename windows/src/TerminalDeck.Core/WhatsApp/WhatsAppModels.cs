namespace TerminalDeck.Core.WhatsApp;

// The WhatsApp Agent Platform client's SHAPE (DESIGN-WHATSAPP.md section 1), mirroring the Mac's
// BackendWhatsAppClient.swift name for name. The engine calls only IWhatsAppTransport; the real one
// (WhatsAppHttpTransport) and the fake one for tests (WhatsAppFakeTransport) implement it.
// No value here ever holds the key except the `key` argument itself, and no implementation may log,
// throw or return it.

/// The kind of an inbound message (Swift: WhatsAppInbound.Kind; C# cannot nest a type named like the property).
public enum WhatsAppInboundKind { Text, Image, Audio, Video, Document, Sticker, Reaction, Other }

/// One message from the agent's creator, as the engine needs it.
/// Id: WhatsApp's message id (wamid), what "mark read" names. From: "user:&lt;id&gt;", the creator, the ONLY value a
/// send may ever be addressed to. Text: the text of a text message. Caption: a picture's, video's or document's
/// caption. MediaId: for GET /media/&lt;id&gt;.
public sealed record WhatsAppInbound(
  string Id,
  string From,
  DateTimeOffset Timestamp,
  WhatsAppInboundKind Kind,
  string? Text = null,
  string? Caption = null,
  string? MediaId = null,
  string? MimeType = null,
  string? FileName = null);

/// What one long-poll gave (Swift: enum WhatsAppPoll).
public abstract record WhatsAppPoll
{
  private WhatsAppPoll() { }

  /// 200: the messages in order and the offset to ask from next.
  public sealed record Messages(IReadOnlyList<WhatsAppInbound> Items, long Next) : WhatsAppPoll
  {
    public bool Equals(Messages? other) => other is not null && Next == other.Next && Items.SequenceEqual(other.Items);
    public override int GetHashCode() => HashCode.Combine(Next, Items.Count);
  }
  /// 204: nothing new; poll again with the same offset.
  public sealed record Nothing : WhatsAppPoll;
  /// 409 (code 1752041): a newer reader took this agent. Stop polling it and re-read the settings.
  public sealed record Replaced : WhatsAppPoll;
  /// 400 code 100 or 401 code 190: the key is wrong or was replaced.
  public sealed record KeyRefused : WhatsAppPoll;
  /// 429, 5xx or no connection: wait this long (already grown by the transport's own back-off), then try again.
  public sealed record BackOff(double Seconds) : WhatsAppPoll;

  public static readonly WhatsAppPoll NothingNew = new Nothing();
  public static readonly WhatsAppPoll ReplacedByNewer = new Replaced();
  public static readonly WhatsAppPoll Refused = new KeyRefused();
}

/// What a send or a status call gave (Swift: enum WhatsAppSent).
public abstract record WhatsAppSent
{
  private WhatsAppSent() { }

  public sealed record Sent : WhatsAppSent;
  public sealed record KeyRefused : WhatsAppSent;
  /// 403 code 131005: not the creator. The engine never addresses anyone else; reported, never retried.
  public sealed record NotCreator : WhatsAppSent;
  /// 429 or 5xx: the transport already waited and retried within its limits; this one was not sent.
  public sealed record BackOff(double Seconds) : WhatsAppSent;
  /// Anything else, in one plain sentence without the key. A send whose answer was lost (500, a timeout, a dropped
  /// connection) is Failed(WhatsAppHttpTransport.UnknownWhetherSent) and is never sent again.
  public sealed record Failed(string Reason) : WhatsAppSent;

  public static readonly WhatsAppSent Done = new Sent();
  public static readonly WhatsAppSent Refused = new KeyRefused();
  public static readonly WhatsAppSent NotTheCreator = new NotCreator();
}

/// Whether WhatsApp accepts a key (checked before a key is added or replaced).
public enum WhatsAppKeyCheck { Accepted, Refused, Unreachable }

/// A media item's bytes, fetched with the same key.
public sealed record WhatsAppMedia(byte[] Data, string MimeType, string? FileName = null)
{
  public bool Equals(WhatsAppMedia? other) => other is not null && MimeType == other.MimeType && FileName == other.FileName && Data.AsSpan().SequenceEqual(other.Data);
  public override int GetHashCode() => HashCode.Combine(MimeType, FileName, Data.Length);
  public override string ToString() => $"WhatsAppMedia {{ {Data.Length} bytes, {MimeType}{(FileName is null ? "" : ", " + FileName)} }}";
}

/// The calls of design section 1. Every call names the agent by its key (the key identifies the agent).
/// Limits per key are the implementation's job: 12 sends a minute, 12 status calls a minute, 15 polls a minute;
/// never two polls at once; sends and status calls for one key strictly one after another.
public interface IWhatsAppTransport
{
  /// One quick look (GET /updates with timeout=0, limit=1, no offset).
  Task<WhatsAppKeyCheck> CheckAsync(string key, CancellationToken cancellationToken = default);
  /// GET /updates?offset=&amp;limit=50&amp;timeout=. offset null = start at the head; 0 = the whole backlog.
  Task<WhatsAppPoll> PollAsync(string key, long? offset, int timeout, CancellationToken cancellationToken = default);
  /// POST /statuses read, with the typing indicator when typing is true (it lasts 25 s; call again to keep it).
  Task<WhatsAppSent> MarkReadAsync(string key, string messageId, bool typing, CancellationToken cancellationToken = default);
  /// POST /messages one text of at most 4096 characters to `to` ("user:&lt;id&gt;", copied from an inbound From).
  Task<WhatsAppSent> SendAsync(string key, string to, string text, CancellationToken cancellationToken = default);
  /// GET /media/&lt;id&gt; then its url with the same key; null when larger than `limit` bytes or not fetched.
  Task<WhatsAppMedia?> MediaAsync(string key, string id, long limit, CancellationToken cancellationToken = default);
}

/// The manual's numbers (quick reference and section 6).
public static class WhatsAppLimits
{
  public const int TextCharacters = 4096;
  public const int CaptionCharacters = 1024;
  public const long ImageBytes = 5L * 1024 * 1024;
  public const long StickerBytes = 500L * 1024;
  public const long OtherMediaBytes = 16L * 1024 * 1024;
  public const int SendsPerMinute = 12;
  public const int StatusesPerMinute = 12;
  public const int PollsPerMinute = 15;
  public const int MediaPerMinute = 12;
  public const int PollTimeoutMaxSeconds = 25;
  public const int PollBatch = 50;
  public const double BackOffCapSeconds = 60;

  /// The largest a received item of this kind can be.
  public static long MaxBytes(WhatsAppInboundKind kind) => kind switch
  {
    WhatsAppInboundKind.Image => ImageBytes,
    WhatsAppInboundKind.Sticker => StickerBytes,
    _ => OtherMediaBytes,
  };
}

/// Time for the transports: the real clock, or a virtual one in tests so nothing ever sleeps.
public interface IWhatsAppClock
{
  DateTimeOffset Now { get; }
  Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
}

public sealed class WhatsAppSystemClock : IWhatsAppClock
{
  public static readonly WhatsAppSystemClock Shared = new();
  public DateTimeOffset Now => DateTimeOffset.UtcNow;
  public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
    delay <= TimeSpan.Zero ? Task.CompletedTask : Task.Delay(delay, cancellationToken);
}

/// Virtual time: a delay moves the clock forward at once and is recorded. Thread-safe.
public sealed class WhatsAppVirtualClock(DateTimeOffset? start = null) : IWhatsAppClock
{
  private readonly object gate = new();
  private DateTimeOffset now = start ?? new DateTimeOffset(2026, 11, 15, 12, 0, 0, TimeSpan.Zero);
  private readonly List<TimeSpan> delays = [];

  public DateTimeOffset Now { get { lock (gate) return now; } }
  public IReadOnlyList<TimeSpan> Delays { get { lock (gate) return delays.ToArray(); } }
  public TimeSpan TotalDelayed { get { lock (gate) return delays.Aggregate(TimeSpan.Zero, (a, b) => a + b); } }

  public void Advance(TimeSpan by) { lock (gate) now += by; }

  public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
  {
    cancellationToken.ThrowIfCancellationRequested();
    if (delay <= TimeSpan.Zero) return Task.CompletedTask;
    lock (gate) { delays.Add(delay); now += delay; }
    return Task.CompletedTask;
  }
}
