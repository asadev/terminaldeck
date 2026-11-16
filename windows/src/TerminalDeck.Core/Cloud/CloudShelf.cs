using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Cloud;

// Lane U1 (15 Nov), the Mac's BackendCloudShelf.swift + NativeCloudShelf.swift: this PC keeps the Cloud service's shelf
// of what is in his Cloud NOW, so his phones and the web list it (and read his notes, instruction files, tasks and text
// files) with every computer off. Contract: Servers note `2026-11-15-cloud-readable-with-no-mac.md` part 7; service
// `cloud/worker/src/shelf.ts`.
//
// ONE source of truth: the shelf is made from the very rows the Your Cloud page lists (CloudContents, with the delete
// rule's marks applied). What never leaves: the Bin, "Only on this PC" / "Not on this PC" rows, saved passwords and
// secret files (their own SEALED lists: CloudShelfSealed.cs), a secret setting's value, sessions (their own routes).
// Names are his words, never ids. Nothing is put unless the join's switch and a signed-in account say so (the round's
// `enabled`).

/// Plain words for rows (the Mac's BackendCloudContentsWords.plain / looksLikeCode, BackendCloudManagerTree.words).
public static class CloudShelfWords
{
  private static readonly Regex[] Code =
  [
    new("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", RegexOptions.CultureInvariant),
    new("[0-9a-fA-F]{12,}", RegexOptions.CultureInvariant),
    new("[A-Za-z0-9+=]{28,}", RegexOptions.CultureInvariant),
    new("\\b[A-Z0-9]{4}( [A-Z0-9]{4}){3,}\\b", RegexOptions.CultureInvariant),
  ];
  public static bool LooksLikeCode(string text) => Code.Any(p => p.IsMatch(text));

  /// The text trimmed, one line, a long one cut between words at 120 characters; null when empty or code-like.
  public static string? Plain(string? text)
  {
    if (text is null) return null;
    var line = string.Join(' ', new string(text.Select(c => char.IsControl(c) ? ' ' : c).ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries));
    if (line.Length == 0) return null;
    if (line.Length > 120)
    {
      var cut = line[..119];
      var space = cut.LastIndexOf(' ');
      if (space > 60) cut = cut[..space];
      line = cut.TrimEnd() + "…";
    }
    return LooksLikeCode(line) ? null : line;
  }

  /// A file name's own words: its date and the random ending the app adds are left out, dashes become spaces, the first
  /// letter is a capital (BackendCloudContentsWords.fileWords, without the cut-at-48 rule).
  public static string? FileWords(string stem)
  {
    var dated = Regex.IsMatch(stem, "^[0-9]{4}-?[0-9]{2}-?[0-9]{2}");
    if (dated)
    {
      stem = Regex.Replace(stem, "-[a-z0-9]{6}(-[0-9]{1,3})?$", "");
      stem = Regex.Replace(stem, "^[0-9]{4}-?[0-9]{2}-?[0-9]{2}(-[0-9]{6})?-?", "");
    }
    var words = Plain(Regex.Replace(stem, "[-_]+", " ").Trim());
    if (words is null) return null;
    return char.ToUpper(words[0], CultureInfo.InvariantCulture) + words[1..];
  }

  private static readonly Dictionary<string, string> ChoiceWords = new(StringComparer.Ordinal)
  {
    ["dark"] = "Dark", ["light"] = "Light", ["system"] = "Same as the Mac", ["claude"] = "Claude", ["codex"] = "Codex", ["gemini"] = "Gemini",
    ["shell"] = "Terminal", ["chime"] = "Chime", ["blip"] = "Blip", ["knock"] = "Knock", ["follow-app"] = "Follow the app",
  };

  /// A setting's value in plain words: "On", "Off", "Dark", "14", "3 chosen"; "Set" for anything long or code-like.
  public static string SettingValue(CloudJson value)
  {
    switch (value)
    {
      case CloudJson.Bool b: return b.Value ? "On" : "Off";
      case CloudJson.Number n: return CloudCanonical.Number(n.Value);
      case CloudJson.String s:
        var t = s.Value.Trim();
        if (t.Length == 0) return "Empty";
        if (ChoiceWords.TryGetValue(t.ToLowerInvariant(), out var known)) return known;
        if (t.Length > 40 || t.Contains('\n') || t.StartsWith('{') || t.StartsWith('[') || Plain(t) is not { } said) return "Set";
        return char.ToUpper(said[0], CultureInfo.InvariantCulture) + said[1..];
      case CloudJson.Array a: return a.Items.Count == 0 ? "None" : a.Items.Count == 1 ? "1 chosen" : a.Items.Count + " chosen";
      case CloudJson.Null: return "Not set";
      default: return "Set";
    }
  }

  /// Review N2: a setting's value leaves only when it is an on/off, a number or one of the app's fixed choices.
  public static string? ShelfValue(string? said)
  {
    said = said?.Trim();
    if (string.IsNullOrEmpty(said)) return null;
    var fixedWords = new HashSet<string>(StringComparer.Ordinal) { "On", "Off", "Empty", "Not set", "None", "Set", "Saved text", "1 chosen" };
    fixedWords.UnionWith(ChoiceWords.Values);
    if (fixedWords.Contains(said)) return said;
    if (Regex.IsMatch(said, "^[0-9][0-9,]* chosen$")) return said;
    if (Regex.IsMatch(said, "^-?[0-9][0-9,]*(\\.[0-9]+)?$")) return said;
    return null;
  }

  /// A setting whose name or record says it holds a key, token, password or other secret: its value never leaves.
  public static bool HoldsSecret(string idAndName)
  {
    var secret = new HashSet<string>(StringComparer.Ordinal) { "key", "keys", "apikey", "token", "tokens", "password", "passwords", "passwd", "passphrase", "secret",
      "secrets", "credential", "credentials", "auth", "oauth", "bearer", "cookie", "cookies", "pin", "otp" };
    return Words(idAndName).Any(secret.Contains);
  }

  /// Lower-case words of a name, split at spaces, punctuation and camelCase; two neighbours joined as well.
  public static IReadOnlyList<string> Words(string text)
  {
    var parts = new List<string>();
    var current = new StringBuilder();
    var previousLower = false;
    void Flush() { if (current.Length > 0) { parts.Add(current.ToString().ToLowerInvariant()); current.Clear(); } }
    foreach (var ch in text)
    {
      if (!char.IsLetterOrDigit(ch)) { Flush(); previousLower = false; continue; }
      if (char.IsUpper(ch) && previousLower) Flush();
      current.Append(ch);
      previousLower = char.IsLower(ch);
    }
    Flush();
    return [.. parts, .. parts.Zip(parts.Skip(1), (a, b) => a + b)];
  }
}

/// JSON bytes exactly as Apple's JSONEncoder writes them with `.sortedKeys` (the Mac's shelf and sealed fingerprints are
/// hashes of these bytes): keys in ordinal order, `/` written `\/`, control characters as `\b \f \n \r \t` or `\u00xx`,
/// everything else (non-ASCII included) as it is, integers plain, absent optionals left out.
public static class CloudShelfJson
{
  /// An object: members whose value is null are left out (Swift's encodeIfPresent).
  public sealed class Obj : List<KeyValuePair<string, object?>>
  {
    public Obj Add(string key, object? value) { Add(new KeyValuePair<string, object?>(key, value)); return this; }
  }

  public static byte[] Encode(object? value)
  {
    var text = new StringBuilder();
    Write(text, value);
    return Encoding.UTF8.GetBytes(text.ToString());
  }

  private static void Write(StringBuilder o, object? value)
  {
    switch (value)
    {
      case null: o.Append("null"); break;
      case string s: Str(o, s); break;
      case bool b: o.Append(b ? "true" : "false"); break;
      case int i: o.Append(i.ToString(CultureInfo.InvariantCulture)); break;
      case long l: o.Append(l.ToString(CultureInfo.InvariantCulture)); break;
      case Obj obj:
        o.Append('{');
        var first = true;
        foreach (var (k, v) in obj.Where(m => m.Value is not null).OrderBy(m => m.Key, StringComparer.Ordinal))
        {
          if (!first) o.Append(',');
          first = false;
          Str(o, k);
          o.Append(':');
          Write(o, v);
        }
        o.Append('}');
        break;
      case System.Collections.IEnumerable list:
        o.Append('[');
        var any = false;
        foreach (var item in list) { if (any) o.Append(','); any = true; Write(o, item); }
        o.Append(']');
        break;
      default: throw new ArgumentException("unsupported JSON value");
    }
  }

  private static void Str(StringBuilder o, string s)
  {
    o.Append('"');
    foreach (var c in s)
    {
      switch (c)
      {
        case '"': o.Append("\\\""); break;
        case '\\': o.Append("\\\\"); break;
        case '/': o.Append("\\/"); break;
        case '\b': o.Append("\\b"); break;
        case '\f': o.Append("\\f"); break;
        case '\n': o.Append("\\n"); break;
        case '\r': o.Append("\\r"); break;
        case '\t': o.Append("\\t"); break;
        default:
          if (c < 0x20) o.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
          else o.Append(c);
          break;
      }
    }
    o.Append('"');
  }
}

public static class CloudShelf
{
  /// Contract §7.1: the kinds the service serves, in the phones' own order. Nothing else is ever put.
  public static readonly IReadOnlyList<CloudContentsKind> ServedKinds =
    [CloudContentsKind.Memory, CloudContentsKind.InstructionFiles, CloudContentsKind.Tasks, CloudContentsKind.Projects, CloudContentsKind.Agents,
     CloudContentsKind.CloudFolder, CloudContentsKind.Artifacts, CloudContentsKind.Settings];
  public static readonly IReadOnlySet<CloudContentsKind> TextKinds = new HashSet<CloudContentsKind>
    { CloudContentsKind.Memory, CloudContentsKind.InstructionFiles, CloudContentsKind.Tasks, CloudContentsKind.CloudFolder, CloudContentsKind.Artifacts };
  public static readonly IReadOnlySet<CloudContentsKind> FileKinds = new HashSet<CloudContentsKind> { CloudContentsKind.CloudFolder, CloudContentsKind.Artifacts };
  public const int PieceBytes = 262_144, TextMaxBytes = 1_048_576, PartMaxRows = 500, PartsMax = 40, BodyBytes = 900_000, TextsPerCall = 64;
  public const long SettleMs = 30_000, DayMs = 86_400_000, RoundStuckMs = 600_000, RebuildMs = 600_000;

  /// The kind's name on the wire (the Mac's `Kind.rawValue`).
  public static string Raw(CloudContentsKind kind) => kind switch
  {
    CloudContentsKind.Memory => "memory",
    CloudContentsKind.Projects => "projects",
    CloudContentsKind.Agents => "agents",
    CloudContentsKind.InstructionFiles => "instructionFiles",
    CloudContentsKind.Tasks => "tasks",
    CloudContentsKind.Settings => "settings",
    CloudContentsKind.Artifacts => "artifacts",
    CloudContentsKind.CloudFolder => "cloudFolder",
    CloudContentsKind.Sessions => "sessions",
    _ => "passwords"
  };

  /// A changed view goes up only once it has stayed the same for `SettleMs` (at launch too).
  public static bool Settled((string Fingerprint, long Since)? held, string fingerprint, long now) =>
    held is { } h && h.Fingerprint == fingerprint && now - h.Since >= SettleMs;
  /// A round that has not finished after 10 minutes no longer blocks the next one.
  public static bool RoundMayStart(long? running, long now) => running is not { } r || now - r >= RoundStuckMs;

  /// One row of a kind's list, exactly the contract's fields (null fields are left out of the JSON).
  public sealed record Row(string Key, string Name, long ChangedAt, string? Place = null, string? ChangedBy = null, long? SizeBytes = null, string? Status = null,
    bool? Binary = null, string? TextHash = null, int? TextBytes = null, int? TextPieces = null, string? FileHash = null, long? FileBytes = null,
    string? FileType = null, bool Grouped = false)
  {
    public CloudShelfJson.Obj Json() => new CloudShelfJson.Obj()
      .Add("key", Key).Add("name", Name).Add("changedAt", ChangedAt).Add("place", Place).Add("changedBy", ChangedBy).Add("sizeBytes", SizeBytes)
      .Add("status", Status).Add("binary", Binary).Add("textHash", TextHash).Add("textBytes", TextBytes).Add("textPieces", TextPieces)
      .Add("fileHash", FileHash).Add("fileBytes", FileBytes).Add("fileType", FileType);
  }

  /// One item going on the shelf: its row, and which page row its text and file are read from.
  public sealed record Entry(Row Row, CloudContentsRow Item, bool Readable, string? TextStamp, bool MayBeFile);

  public sealed record TextFact(string Hash, int Bytes, int Pieces);

  /// The shelf's entries per served kind, from the page's own rows. Only what stands in the Cloud: never a marked row.
  public static Dictionary<CloudContentsKind, List<Entry>> Entries(IReadOnlyList<CloudContentsRow> rows, Func<CloudContentsKind, ICloudShelfReadable?> readers)
  {
    var made = ServedKinds.ToDictionary(k => k, _ => new List<Entry>());
    var keys = ServedKinds.ToDictionary(k => k, _ => new HashSet<string>(StringComparer.Ordinal));
    foreach (var item in rows)
    {
      if (!made.TryGetValue(item.Kind, out var list) || item.State != CloudItemState.InSync || item.Id.StartsWith("marked|", StringComparison.Ordinal)) continue;
      if (Clip(CloudShelfWords.Plain(item.Name), 128) is not { } name) continue;
      var key = Key(item.Id);
      if (!keys[item.Kind].Add(key)) continue;
      var reader = readers(item.Kind);
      var grouped = reader?.Grouped(item) == true;
      var isText = reader?.IsText(item) == true;
      var place = item.Kind == CloudContentsKind.Settings ? string.Join(" › ", item.Folder) : string.Join(" · ", item.Folder);
      string? status = Clip(CloudShelfWords.Plain(reader?.Status(item) ?? item.Detail), 64);
      if (item.Kind == CloudContentsKind.Settings && !grouped) status = CloudShelfWords.HoldsSecret(item.Id + " " + item.Name) ? null : CloudShelfWords.ShelfValue(item.Detail);
      var row = new Row(key, name, Math.Max(0, item.ChangedAt), Clip(CloudShelfWords.Plain(place), 512), Clip(CloudShelfWords.Plain(item.ChangedBy), 64),
        item.Bytes is { } b ? Math.Max(0, b) : null, status, Grouped: grouped);
      if (item.Kind is CloudContentsKind.CloudFolder or CloudContentsKind.Artifacts or CloudContentsKind.InstructionFiles && !isText) row = row with { Binary = true };
      var readable = reader is not null && TextKinds.Contains(item.Kind) && !grouped && (item.Kind == CloudContentsKind.Tasks || isText);
      list.Add(new Entry(row, item, readable, readable ? item.Id + "|" + item.ChangedAt.ToString(CultureInfo.InvariantCulture) + "|" + (item.Bytes ?? -1).ToString(CultureInfo.InvariantCulture) : null,
        FileKinds.Contains(item.Kind) && !grouped));
    }
    foreach (var list in made.Values) list.Sort((a, b) => string.CompareOrdinal(a.Row.Key, b.Row.Key));
    return made;
  }

  /// The Mac's own item key: the page's plain id, hashed only when long.
  public static string Key(string id) => Encoding.UTF8.GetByteCount(id) <= 512 ? id : "h:" + Hash(Encoding.UTF8.GetBytes(id));
  public static string? Clip(string? text, int limit)
  {
    if (string.IsNullOrEmpty(text)) return null;
    var elements = StringInfo.ParseCombiningCharacters(text);
    return elements.Length <= limit ? text : text[..elements[limit - 1]] + "…";
  }
  public static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

  /// The whole text's facts (contract §7.4): SHA-256 of its UTF-8, its length and how many pieces.
  public static TextFact Fact(string text)
  {
    var data = Encoding.UTF8.GetBytes(text);
    return new TextFact(Hash(data), data.Length, Pieces(text).Count);
  }

  /// The text in pieces of at most 256 KiB of UTF-8 each, cut between characters (Unicode scalars); "" is one piece.
  public static IReadOnlyList<string> Pieces(string text)
  {
    if (Encoding.UTF8.GetByteCount(text) <= PieceBytes) return [text];
    var made = new List<string>();
    var current = new StringBuilder();
    var size = 0;
    foreach (var rune in text.EnumerateRunes())
    {
      var width = rune.Utf8SequenceLength;
      if (size + width > PieceBytes) { made.Add(current.ToString()); current.Clear(); size = 0; }
      current.Append(rune.ToString());
      size += width;
    }
    if (current.Length > 0 || made.Count == 0) made.Add(current.ToString());
    return made;
  }

  /// One kind's view, as a fingerprint: SHA-256 of the rows' sorted-keys JSON, a grouped row's date, size and status
  /// left out. Byte for byte the Mac's (reference cases in cloud-shelf-vectors.json).
  public static string Fingerprint(IReadOnlyList<Row> rows) =>
    Hash(CloudShelfJson.Encode(rows.Select(r => r.Grouped ? r with { ChangedAt = 0, SizeBytes = null, Status = null } : r).Select(r => r.Json()).ToList()));

  /// The list in parts: at most 500 rows and `BodyBytes` each, at least one part.
  public static IReadOnlyList<IReadOnlyList<Row>> Parts(IReadOnlyList<Row> rows)
  {
    var made = new List<IReadOnlyList<Row>>();
    var current = new List<Row>();
    var size = 0;
    foreach (var row in rows)
    {
      var width = CloudShelfJson.Encode(row.Json()).Length + 1;
      if (current.Count > 0 && (current.Count >= PartMaxRows || size + width > BodyBytes)) { made.Add(current); current = []; size = 0; }
      current.Add(row);
      size += width;
    }
    if (current.Count > 0 || made.Count == 0) made.Add(current);
    return made;
  }

  /// A Cloud folder or artifact file's text: a normal file inside `root`, read without following a link, at most 1 MB,
  /// UTF-8 with no zero byte, holding no secret by the app's own rules; null otherwise.
  public static string? FileText(string root, string relative)
  {
    if (relative.Length == 0 || CloudFolderDisk.StampOf(root, relative) is not { } stamp || stamp.Bytes > TextMaxBytes) return null;
    if (CloudFolderDisk.Read(root, relative) is not { IsFile: true } found || found.Bytes!.Length > TextMaxBytes || CloudShelfFiles.HoldsSecret(relative, found.Bytes)) return null;
    return CloudContentsText.Text(found.Bytes);
  }

  private static readonly Dictionary<string, string> Types = new(StringComparer.OrdinalIgnoreCase)
  {
    ["png"] = "image/png", ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg", ["gif"] = "image/gif", ["webp"] = "image/webp", ["heic"] = "image/heic",
    ["heif"] = "image/heif", ["bmp"] = "image/bmp", ["tif"] = "image/tiff", ["tiff"] = "image/tiff", ["avif"] = "image/avif", ["svg"] = "image/svg+xml",
    ["pdf"] = "application/pdf", ["txt"] = "text/plain", ["md"] = "text/markdown", ["csv"] = "text/csv", ["html"] = "text/html", ["htm"] = "text/html",
    ["json"] = "application/json", ["xml"] = "application/xml", ["zip"] = "application/zip", ["mp3"] = "audio/mpeg", ["m4a"] = "audio/x-m4a", ["wav"] = "audio/wav",
    ["aac"] = "audio/aac", ["flac"] = "audio/flac", ["ogg"] = "audio/ogg", ["mp4"] = "video/mp4", ["mov"] = "video/quicktime", ["m4v"] = "video/x-m4v",
    ["webm"] = "video/webm", ["mpeg"] = "video/mpeg", ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  };
  /// The type from the name's ending, lower case; unknown = `application/octet-stream`.
  public static string FileType(string relative)
  {
    var dot = relative.LastIndexOf('.');
    var slash = relative.LastIndexOf('/');
    return dot > slash + 1 && Types.TryGetValue(relative[(dot + 1)..], out var type) ? type : "application/octet-stream";
  }
}

/// The shelf routes of the service, signed exactly like the change feed's control calls (bearer token + device proof
/// over the `/v1` path), through their own door: never the feed's back-off. Only these routes can be named.
public sealed class CloudShelfClient(CloudSyncEndpoint endpoint, ICloudSyncAuth auth, ICloudSyncHttp http, Func<long>? serviceNow = null)
{
  public const int MaximumBytes = 1_600_000;
  public static readonly IReadOnlyList<string> Routes = ["/shelf", "/shelf/list", "/shelf/texts", "/shelf/files", "/shelf/setting",
    "/shelf/sealed/missing", "/shelf/sealed/pieces", "/shelf/sealed/index", "/shelf/sealed/clear"];
  private readonly Func<long> now = serviceNow ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

  public static bool IsShelfPath(string path)
  {
    var parts = path.Split('?', 2);
    if (!Routes.Contains(parts[0])) return false;
    return parts.Length == 1 || parts[0] == "/shelf" && Regex.IsMatch(parts[1], "^kind=[A-Za-z]{1,32}$");
  }

  public async Task<CloudChatsAnswer> SendAsync(string method, string path, byte[] body, CancellationToken ct = default)
  {
    if (method is not ("GET" or "POST") || !IsShelfPath(path) || method == "GET" && body.Length > 0 || body.Length > MaximumBytes) throw new CloudFailure("invalid_request");
    var credentials = await auth.CredentialsAsync(ct);
    var requestId = Guid.NewGuid().ToString("D");
    var proof = auth.Proof(method, "/v1" + path, body, now(), requestId);
    if (!proof.TryGetValue("X-TD-Device", out var device) || device != credentials.DeviceId) throw new CloudFailure("invalid_request");
    var headers = new Dictionary<string, string>(proof, StringComparer.OrdinalIgnoreCase)
    {
      ["Authorization"] = "Bearer " + credentials.AccessToken, ["Cache-Control"] = "no-store", ["Content-Type"] = "application/json"
    };
    var answer = await http.SendAsync(new(method, endpoint.Control(path), headers, body, MaximumBytes), ct);
    if (answer.Body.Length > MaximumBytes) throw new CloudFailure("invalid_request");
    return new(answer.Status, answer.Body);
  }

  public CloudChatsSend Door(CancellationToken ct = default) => (method, path, body) => SendAsync(method, path, body, ct);
}

/// The putter: quiet, in the background. One per signed-in identity; every call goes through `send` (the shelf door).
/// Keeps its small state beside the identity's sync store (`shelf.json`): per kind the fingerprint last put, when, and
/// whether texts and files are still owed; the text hash cache; whether it is on; when the shelf was last put and from
/// which device.
public sealed partial class CloudShelfPutter
{
  public sealed class KindState
  {
    public string? Fingerprint { get; set; }
    public long? PutAt { get; set; }
    public int? Count { get; set; }
    public bool TextsOwed { get; set; }
    public List<CloudShelfFiles.NeedFile>? FilesOwed { get; set; }
    public long? FilesAskedAt { get; set; }
    public int? FilesAsked { get; set; }
    public int? FilesDone { get; set; }
    public long? FilesHoldUntil { get; set; }
  }
  public sealed class State
  {
    public bool On { get; set; } = true;
    public Dictionary<string, KindState> Kinds { get; set; } = [];
    public Dictionary<string, CloudShelf.TextFact> Texts { get; set; } = [];
    public long? AsOf { get; set; }
    public string? From { get; set; }
    public Dictionary<string, CloudShelfFiles.FileFact>? Files { get; set; }
    public List<string>? FileKinds { get; set; }
    public long? FileKindsAt { get; set; }
  }
  public enum Outcome { Put, Unchanged, Behind, Off, Missing, Later }
  public sealed record Put(Outcome Outcome, int Count = 0, int Texts = 0);

  private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
  private readonly CloudChatsSend send;
  private readonly string? file;
  private readonly SemaphoreSlim one = new(1, 1);
  private readonly Dictionary<CloudContentsKind, long> retryAt = [];
  public State Current { get; private set; }
  /// Set by a 404: the routes do not exist yet. Nothing more is sent until the next start.
  public bool Missing { get; private set; }

  public CloudShelfPutter(CloudChatsSend send, string? file)
  {
    this.send = send;
    this.file = file;
    State? saved = null;
    try { if (file is not null && File.Exists(file)) saved = JsonSerializer.Deserialize<State>(File.ReadAllBytes(file), Json); } catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    Current = saved ?? new State();
  }

  internal enum Kind { Ok, Refused, Lost }
  internal sealed record Answer(Kind Kind, byte[] Data, int Status = 0, string? Code = null, int? RetryAfterMs = null);

  internal async Task<Answer> CallAsync(string method, string path, byte[] body, bool quiet404 = false)
  {
    if (Missing) return new(Kind.Refused, [], 404, "not_found");
    CloudChatsAnswer answered;
    try { answered = await send(method, path, body); }
    catch (Exception) { return new(Kind.Lost, []); }
    if (answered.Status is >= 200 and < 300) return new(Kind.Ok, answered.Data);
    string? code = null;
    int? retry = null;
    try
    {
      using var doc = JsonDocument.Parse(answered.Data);
      if (doc.RootElement.TryGetProperty("error", out var error))
      {
        if (error.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String) code = c.GetString();
        if (error.TryGetProperty("retryAfterMs", out var r) && r.TryGetInt32(out var ms)) retry = ms;
      }
    }
    catch (JsonException) { }
    if (answered.Status == 404 && !quiet404) Missing = true;
    return new(Kind.Refused, answered.Data, answered.Status, code, retry);
  }

  internal void Save()
  {
    if (file is null) return;
    try
    {
      Directory.CreateDirectory(Path.GetDirectoryName(file)!);
      var temp = file + ".tmp";
      File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(Current, Json));
      File.Move(temp, file, true);
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
  }

  internal static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

  public sealed record StatusKind(string Kind, string? PutId, long? AsOf, string? FromDevice, int? Count, string? ThroughSeq);
  public sealed record StatusLimits(List<string>? FileKinds);
  public sealed record Status(bool? On, List<StatusKind>? Kinds, List<string>? NeedTexts, List<CloudShelfFiles.NeedFile>? NeedFiles, StatusLimits? Limits);

  /// `GET /v1/shelf` (or one kind's, with what it still needs). Keeps the account's setting and the newest put.
  public async Task<Status?> StatusAsync(CloudContentsKind? kind = null)
  {
    var answer = await CallAsync("GET", "/shelf" + (kind is { } k ? "?kind=" + CloudShelf.Raw(k) : ""), []);
    if (answer.Kind != Kind.Ok) return null;
    Status? status;
    try { status = JsonSerializer.Deserialize<Status>(answer.Data, Json); } catch (JsonException) { return null; }
    if (status is null) return null;
    if (status.On is { } on) Current.On = on;
    if (kind is null) { Current.FileKinds = status.Limits?.FileKinds ?? []; Current.FileKindsAt = Now(); }
    if (status.Kinds?.Where(r => r.AsOf is not null).MaxBy(r => r.AsOf) is { } newest)
    {
      Current.AsOf = newest.AsOf;
      Current.From = CloudShelfWords.Plain(newest.FromDevice) ?? Current.From;
    }
    Save();
    return status;
  }

  /// The person's switch (contract §7.8): OFF empties the shelf on the service and stops; ON puts everything again.
  public async Task<bool> SetOnAsync(bool on)
  {
    Current.On = on;
    if (on) foreach (var k in Current.Kinds.Values) k.Fingerprint = null;
    Save();
    if ((await CallAsync("POST", "/shelf/setting", CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("on", on)))).Kind != Kind.Ok) return false;
    if (!on) { Current.Kinds = []; Current.AsOf = null; Current.From = null; Save(); }
    return true;
  }

  public CloudShelf.TextFact? KnownText(string stamp) => Current.Texts.GetValueOrDefault(stamp);
  /// Keeps only the facts of texts still listed, so the cache never grows past the shelf.
  public void Remember(Dictionary<string, CloudShelf.TextFact> facts)
  {
    if (facts.Count == Current.Texts.Count && facts.All(f => Current.Texts.TryGetValue(f.Key, out var v) && v == f.Value)) return;
    Current.Texts = facts;
    Save();
  }

  /// Puts one kind's list when it changed (or `force`, the daily put), then exactly the texts the service asks for.
  /// `text` hands the whole text for a hash (null = not readable now: it stays owed to the next put).
  public async Task<Put> PutAsync(CloudContentsKind kind, IReadOnlyList<CloudShelf.Row> rows, string throughSeq, string? from, Func<string, Task<string?>> text,
    bool force = false, long? at = null)
  {
    var now = at ?? Now();
    if (!CloudShelf.ServedKinds.Contains(kind)) return new(Outcome.Unchanged);
    if (!Current.On) return new(Outcome.Off);
    if (Missing) return new(Outcome.Missing);
    if (retryAt.TryGetValue(kind, out var wait) && now < wait) return new(Outcome.Later);
    var raw = CloudShelf.Raw(kind);
    var fingerprint = CloudShelf.Fingerprint(rows);
    var known = Current.Kinds.GetValueOrDefault(raw) ?? new KindState();
    if (known.TextsOwed && known.Fingerprint == fingerprint && !force)
    {
      if ((await StatusAsync(kind))?.NeedTexts is not { } needed) return new(Missing ? Outcome.Missing : Outcome.Later);
      var resumed = await SendTextsAsync(kind, needed, text);
      if (resumed.Complete) { known.TextsOwed = false; Current.Kinds[raw] = known; Save(); }
      return new(Outcome.Put, known.Count ?? rows.Count, resumed.Count);
    }
    if (!force && known.Fingerprint == fingerprint) return new(Outcome.Unchanged);
    var parts = CloudShelf.Parts(rows);
    if (parts.Count > CloudShelf.PartsMax) return new(Outcome.Later);
    var putId = Guid.NewGuid().ToString("D");
    JsonElement? last = null;
    for (var index = 0; index < parts.Count; index++)
    {
      var body = CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", raw).Add("putId", putId).Add("part", index).Add("parts", parts.Count)
        .Add("throughSeq", throughSeq).Add("items", parts[index].Select(r => r.Json()).ToList()));
      var answer = await CallAsync("POST", "/shelf/list", body);
      switch (answer.Kind)
      {
        case Kind.Ok:
          if (index == parts.Count - 1) try { last = JsonDocument.Parse(answer.Data).RootElement.Clone(); } catch (JsonException) { }
          break;
        case Kind.Lost: return new(Outcome.Later);
        default:
          if (answer.Status == 404) return new(Outcome.Missing);
          if (answer.Status == 409 && answer.Code == "shelf_behind")
          {
            known.Fingerprint = fingerprint; known.PutAt = now; known.FilesOwed = null; Current.Kinds[raw] = known; Save();
            return new(Outcome.Behind);
          }
          if (answer.Status == 409 && answer.Code == "shelf_off") { Current.On = false; Save(); return new(Outcome.Off); }
          retryAt[kind] = now + (answer.Status == 429 ? Math.Max(answer.RetryAfterMs ?? 0, CloudShelf.SettleMs) : CloudShelf.SettleMs);
          return new(Outcome.Later);
      }
    }
    if (last is not { } done || !done.TryGetProperty("accepted", out var accepted) || accepted.ValueKind != JsonValueKind.True) return new(Outcome.Later);
    known.Fingerprint = fingerprint;
    known.PutAt = now;
    known.Count = done.TryGetProperty("count", out var c) && c.TryGetInt32(out var n) ? n : rows.Count;
    var needTexts = done.TryGetProperty("needTexts", out var nt) && nt.ValueKind == JsonValueKind.Array ? nt.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToList() : [];
    known.TextsOwed = needTexts.Count > 0;
    List<CloudShelfFiles.NeedFile>? needFiles = null;
    if (FilesLive(kind) && done.TryGetProperty("needFiles", out var nf) && nf.ValueKind == JsonValueKind.Array)
      try { needFiles = nf.Deserialize<List<CloudShelfFiles.NeedFile>>(Json); } catch (JsonException) { }
    CloudShelfFiles.Ask(known, kind, needFiles, now);
    Current.Kinds[raw] = known;
    Current.AsOf = done.TryGetProperty("asOf", out var asOf) && asOf.TryGetInt64(out var a) ? a : now;
    Current.From = from ?? Current.From;
    Save();
    if (needTexts.Count == 0) return new(Outcome.Put, known.Count ?? 0);
    var sent = await SendTextsAsync(kind, needTexts, text);
    if (sent.Complete) { Current.Kinds[raw].TextsOwed = false; Save(); }
    return new(Outcome.Put, known.Count ?? 0, sent.Count);
  }

  /// `POST /v1/shelf/texts`: the asked-for texts in pieces, at most 64 pieces and `BodyBytes` a call. A text whose bytes
  /// no longer match its hash is not sent: the next put lists the new one.
  private async Task<(int Count, bool Complete)> SendTextsAsync(CloudContentsKind kind, IReadOnlyList<string> hashes, Func<string, Task<string?>> text)
  {
    if (!CloudShelf.TextKinds.Contains(kind)) return (0, true);
    var batch = new List<CloudShelfJson.Obj>();
    var size = 0;
    var sent = 0;
    var complete = true;
    foreach (var hash in hashes.Distinct().OrderBy(h => h, StringComparer.Ordinal))
    {
      string? whole;
      try { whole = await text(hash); } catch { whole = null; }
      if (whole is null || CloudShelf.Hash(Encoding.UTF8.GetBytes(whole)) != hash) { complete = false; continue; }
      var pieces = CloudShelf.Pieces(whole);
      for (var index = 0; index < pieces.Count; index++)
      {
        var made = new CloudShelfJson.Obj().Add("hash", hash).Add("piece", index).Add("text", pieces[index]);
        var width = CloudShelfJson.Encode(made).Length + 1;
        if (batch.Count > 0 && (batch.Count >= CloudShelf.TextsPerCall || size + width > CloudShelf.BodyBytes))
        {
          if (!await PostTextsAsync(kind, batch)) return (sent, false);
          batch = [];
          size = 0;
        }
        batch.Add(made);
        size += width;
      }
      sent++;
    }
    if (batch.Count > 0 && !await PostTextsAsync(kind, batch)) return (sent, false);
    return (sent, complete);
  }

  private async Task<bool> PostTextsAsync(CloudContentsKind kind, List<CloudShelfJson.Obj> batch) =>
    (await CallAsync("POST", "/shelf/texts", CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", CloudShelf.Raw(kind)).Add("texts", batch)))).Kind == Kind.Ok;
}

/// One shelf round (NativeCloudShelf.round on Windows): reads the page's rows, puts each served kind whose view changed
/// once it has settled 30 s (at launch too), once a day, texts when the service asks; then the sealed round; then the
/// files the service asked for. Never two rounds at once (a stuck one stops blocking after 10 minutes). One plain log
/// line per put or refusal; never a name, a place or a value.
public sealed class CloudShelfRound
{
  private readonly CloudShelfPutter putter;
  private readonly CloudContents contents;
  private readonly Func<bool> ready;
  private readonly Func<string> throughSeq;
  private readonly Func<string?> from;
  private readonly Action<string> note;
  private readonly Func<long> clock;
  private readonly CloudShelfSealedRound? sealedRound;
  private readonly CloudDayBudget? budget;
  private readonly Dictionary<CloudContentsKind, (string Fingerprint, long Since)> seen = [];
  private Dictionary<string, (CloudContentsKind Kind, CloudContentsRow Row)> textSources = new(StringComparer.Ordinal);
  private Dictionary<string, (string Root, string Relative)> fileSources = new(StringComparer.Ordinal);
  private (Guid Token, long Since)? busy;
  private bool launchPending = true, unsettled;
  private string lastSignal = "";
  private long lastBuild, filesLookTried;

  /// - `ready`: signed in to an account, Cloud on here, the first full pull done, AND the join's switch on.
  /// - `throughSeq`: the feed position this PC has read through; `from`: this PC's name.
  public CloudShelfRound(CloudShelfPutter putter, CloudContents contents, Func<bool> ready, Func<string> throughSeq, Func<string?> from, Action<string> note,
    CloudShelfSealedRound? sealedRound = null, CloudDayBudget? budget = null, Func<long>? clock = null)
  {
    this.putter = putter; this.contents = contents; this.ready = ready; this.throughSeq = throughSeq; this.from = from; this.note = note;
    this.sealedRound = sealedRound; this.budget = budget; this.clock = clock ?? CloudShelfPutter.Now;
  }

  public CloudShelfPutter Putter => putter;

  private bool Ready() { try { return ready(); } catch { return false; } }

  /// One round. `signal`: what moved since the last round (feed position, queue); an unchanged signal skips the build
  /// unless something settles, is owed, is due daily, or 10 minutes passed.
  public async Task RunAsync(string signal, CancellationToken cancel = default)
  {
    var now = clock();
    if (!Ready() || !CloudShelf.RoundMayStart(busy?.Since, now)) return;
    if (busy is not null) note("cloud shelf: a round has not finished for 10 minutes; starting a new one");
    var token = Guid.NewGuid();
    busy = (token, now);
    try { await RoundAsync(signal, now, cancel); }
    finally { if (busy?.Token == token) busy = null; }
  }

  private async Task RoundAsync(string signal, long now, CancellationToken cancel)
  {
    if (putter.Missing) return;
    if (now - (putter.Current.FileKindsAt ?? 0) >= CloudShelf.DayMs && now - filesLookTried >= CloudShelf.RebuildMs)
    {
      filesLookTried = now;
      await putter.StatusAsync();
    }
    var state = putter.Current;
    var dailyDue = CloudShelf.ServedKinds.Any(k => now - (state.Kinds.GetValueOrDefault(CloudShelf.Raw(k))?.PutAt ?? 0) >= CloudShelf.DayMs);
    var owed = state.Kinds.Values.Any(k => k.TextsOwed);
    var sealedSettling = sealedRound?.Settling ?? false;
    if (!(launchPending || unsettled || owed || dailyDue || sealedSettling || signal != lastSignal || now - lastBuild >= CloudShelf.RebuildMs))
    {
      if (sealedRound is not null && sealedRound.RetryDue()) await sealedRound.RunAsync(throughSeq(), from(), false, signal);
      await SendFilesAsync();
      return;
    }
    lastSignal = signal;
    lastBuild = now;
    var snapshot = await contents.ReadAsync(cancel);
    if (!Ready()) return;
    ICloudShelfReadable? Reader(CloudContentsKind k) => contents.Source(k) as ICloudShelfReadable;
    var entries = CloudShelf.Entries(snapshot.Rows, Reader);

    // Files: the Cloud folder's and artifacts' files, each hashed only when its size or change time moved.
    var asks = new List<CloudShelfFiles.FileAsk>();
    foreach (var kind in CloudShelf.FileKinds.OrderBy(k => CloudShelf.Raw(k), StringComparer.Ordinal))
    {
      if (!putter.FilesLive(kind) || Reader(kind) is not { } reader) continue;
      foreach (var entry in entries[kind])
        if (entry.MayBeFile && reader.FileAt(entry.Item) is { } at) asks.Add(new(entry.Item.Id, kind, at.Root, at.Relative, reader.IsText(entry.Item)));
    }
    var found = asks.Count == 0 ? new CloudShelfFiles.FilesFound() : await Task.Run(() => CloudShelfFiles.FileFacts(asks, putter.KnownFiles()), cancel);
    var askedBy = asks.GroupBy(a => a.Item).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);

    var facts = new Dictionary<string, CloudShelf.TextFact>(StringComparer.Ordinal);
    var sources = new Dictionary<string, (CloudContentsKind, CloudContentsRow)>(StringComparer.Ordinal);
    var files = new Dictionary<string, (string, string)>(StringComparer.Ordinal);
    var rows = new Dictionary<CloudContentsKind, List<CloudShelf.Row>>();
    foreach (var kind in CloudShelf.ServedKinds)
    {
      var made = new List<CloudShelf.Row>();
      foreach (var entry in entries[kind])
      {
        var row = entry.Row;
        if (entry.Readable && entry.TextStamp is { } stamp && Reader(kind) is { } reader)
        {
          var fact = putter.KnownText(stamp);
          if (fact is null)
          {
            string? text = null;
            try { text = await reader.TextAsync(entry.Item, cancel); } catch (Exception e) when (e is not OperationCanceledException) { }
            if (text is not null) fact = CloudShelf.Fact(text);
          }
          if (fact is not null && fact.Bytes <= CloudShelf.TextMaxBytes)
          {
            row = row with { TextHash = fact.Hash, TextBytes = fact.Bytes, TextPieces = fact.Pieces };
            facts[stamp] = fact;
            sources[fact.Hash] = (kind, entry.Item);
          }
        }
        if (found.ByItem.TryGetValue(entry.Item.Id, out var hit) && askedBy.TryGetValue(entry.Item.Id, out var ask))
        {
          row = CloudShelfFiles.WithFile(row, hit.Fact);
          if (row.FileHash is { } h) files[CloudShelf.Raw(kind) + "|" + h] = (ask.Root, ask.Relative);
        }
        made.Add(row);
      }
      rows[kind] = made;
    }
    if (!Ready()) return;
    putter.Remember(facts);
    textSources = sources;
    putter.RememberFiles(found.Keep);
    fileSources = files;
    if (found.Pending) unsettled = true;
    var seq = throughSeq();
    var name = from();
    var atLaunch = launchPending;
    unsettled = false;
    foreach (var kind in CloudShelf.ServedKinds)
    {
      var list = rows[kind];
      var fingerprint = CloudShelf.Fingerprint(list);
      var known = putter.Current.Kinds.GetValueOrDefault(CloudShelf.Raw(kind));
      var changed = known?.Fingerprint != fingerprint;
      var daily = clock() - (known?.PutAt ?? 0) >= CloudShelf.DayMs;
      if (!changed && !daily && known?.TextsOwed != true) { seen.Remove(kind); continue; }
      if (changed && !CloudShelf.Settled(seen.TryGetValue(kind, out var held) ? held : null, fingerprint, clock()))
      {
        if (!seen.TryGetValue(kind, out var was) || was.Fingerprint != fingerprint) seen[kind] = (fingerprint, clock());
        unsettled = true;
        continue;
      }
      var outcome = await putter.PutAsync(kind, list, seq, name, TextAsync, force: daily && !changed, at: clock());
      switch (outcome.Outcome)
      {
        case CloudShelfPutter.Outcome.Missing: return;
        case CloudShelfPutter.Outcome.Off: return;
        case CloudShelfPutter.Outcome.Later: unsettled = true; break;
        case CloudShelfPutter.Outcome.Put:
          seen.Remove(kind);
          if (changed || daily) note("cloud shelf: " + CloudShelf.Raw(kind) + " put, " + outcome.Count.ToString(CultureInfo.InvariantCulture) + " items, through position " + seq);
          break;
        case CloudShelfPutter.Outcome.Behind:
          seen.Remove(kind);
          note("cloud shelf: " + CloudShelf.Raw(kind) + " not put: another device put a newer view");
          break;
        default: seen.Remove(kind); break;
      }
      if (!Ready()) return;
    }
    if (sealedRound is not null) await sealedRound.RunAsync(seq, name, atLaunch, signal);
    launchPending = false;
    await SendFilesAsync();
  }

  /// A listed text, read again when the service asks for it.
  private async Task<string?> TextAsync(string hash)
  {
    if (!textSources.TryGetValue(hash, out var source) || contents.Source(source.Kind) is not ICloudShelfReadable reader) return null;
    return await reader.TextAsync(source.Row, CancellationToken.None);
  }

  /// The files the service asked for, one at a time, at most 8 MiB a round, inside half of the Cloud folder's daily send
  /// allowance (booked in the same budget). Never before the first build of this start.
  private async Task SendFilesAsync()
  {
    if (!Ready() || launchPending || budget is null) return;
    var sources = fileSources;
    await putter.SendFilesAsync(clock(),
      bytes => budget.Sent(clock() / CloudShelf.DayMs) + bytes <= CloudShelfFiles.FilesDayShare,
      bytes => budget.Add(bytes, clock() / CloudShelf.DayMs),
      (kind, hash) => Task.Run(() => sources.TryGetValue(CloudShelf.Raw(kind) + "|" + hash, out var s) ? CloudShelfFiles.FileBytes(s.Item1, s.Item2, hash) : null));
  }
}
