using System.Collections.Concurrent;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Cloud;

/// Sessions and chats in the Cloud, the PC part (the Mac's BackendCloudChats.swift; owner, 15 Nov 2026: "every session
/// and chat of his account is listed on every device, by account and not by machine"; "chat histories live in the Cloud
/// and are kept until he deletes them, however big"). Contract: Servers note `2026-11-15-cloud-chats.md`.
///
/// This PC puts ITS OWN list of sessions (what its side panel lists) and each session's chat as it grows:
/// - `raw`: the AI's own history file, exact to the byte, plus each Claude `tool-results` file as its own `tool:<name>`
///   stream;
/// - `read`: the readable messages as the event lines the phones already draw (`CloudChatsReadable`);
/// - `snap`: an app chat's saved `chat.json` (runtime fields left out), when it has been quiet 2 minutes.
/// Only what was added goes up, about every 30 s while something grew, nothing at all while idle. Old histories catch up
/// in the background as closed pieces, readable copies first, newest-used first, one call per 2 s, resumable.
/// Never deletes anything: closing a session only takes it off the list (its chat stays). The Bin is by hand only.
public static class CloudChats
{
  /// Contract: close `raw` at 4 MiB raw, `read` at 1 MiB raw.
  public const int RawPieceBytes = 4 * 1_048_576;
  public const int ReadPieceBytes = 1_048_576;
  /// The most raw bytes ONE tick part carries (more waits for the next tick, or is sent as pieces).
  public const int PartRawBytes = 4 * 1_048_576;
  /// The base64 bytes one tick body carries at most (contract: 8 MiB a call).
  public const int TickBodyBytes = 6 * 1_048_576;
  /// A tail is closed into a piece after 64 ticks or 10 minutes without growth.
  public const int TailPartsMax = 64;
  public const long QuietCloseMs = 600_000;
  /// The list goes up when it changed, at most once per 15 s, inside the tick.
  public const long ListEveryMs = 15_000;
  /// An app chat's saved file goes up 2 minutes after it last changed.
  public const long SnapQuietMs = 120_000;
  /// Gemini rewrites its chat file whole: its raw copy goes up once it has been quiet 10 minutes.
  public const long GeminiQuietMs = 600_000;
  /// A last history line with no newline counts as whole once the file has not grown for a minute.
  public const long LineQuietMs = 60_000;
  public const int MaximumRawBytes = 8 * 1_048_576;
  public const int ToolStreamsMax = 256;
  public const int TailCheckBytes = 4_096;

  public sealed record Project(string CloudRef, string Name);
  /// One row of this PC's list: exactly the contract's keys (an unknown key would drop the row), null keys left out.
  public sealed record Row(string SessionId, string Name, long LastUsedAt, Project? Project = null, string? Cwd = null, string? Ai = null,
    string? Login = null, string? Kind = null, string? Status = null, long? StartedAt = null, string? ConversationId = null, long? CodeAt = null)
  {
    public int? V { get; init; } = 1;
  }
  /// Where a session's chat is read from on this PC. A plain terminal has none ("A terminal, nothing to read").
  public sealed record Source(string? Raw = null, IReadOnlyList<string>? Tools = null, CloudChatsReadable.Format? Readable = null, string? Snap = null, string? Provider = null)
  {
    public IReadOnlyList<string> ToolFiles => Tools ?? [];
    public static Source None { get; } = new();
  }
  public sealed record Listed(Row Row, Source Source);

  internal static readonly JsonSerializerOptions Wire = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

  /// The side panel's states in the contract's words (the phones' status words).
  public static string Status(string phone) => phone switch
  {
    "working" => "running",
    "input" => "needsYou",
    "exited" => "ended",
    _ => "idle"
  };
  /// The id the Cloud's session rows name a machine by (their `machine`): the service's own rule, first 32 hex of
  /// SHA-256("TD-CHATS-MACHINE-1\n" + account subject + "\n" + machine), machine = its machineId, else its device id.
  public static string MachineRef(string subject, string machine) => Hex(Encoding.UTF8.GetBytes("TD-CHATS-MACHINE-1\n" + subject + "\n" + machine))[..32];

  /// This PC's row for one session it lists. `name`: the side panel's own title for it when known.
  public static Row RowFor(CloudChatsSession session, string? name, IReadOnlyList<TerminalDeck.Core.Projects.Project> projects)
  {
    var project = ProjectFor(session.ProjectId, session.Cwd, projects);
    var title = string.IsNullOrWhiteSpace(name) ? session.Title : name.Trim();
    return new(session.Id, Clip(title, 200) ?? "Session", session.LastUsedAt, project, Clip(session.Cwd, 512), Clip(session.Provider, 32),
      Clip(session.Login, 120), session.Chat ? "chat" : session.Kind, Status(session.Status), session.CreatedAt, Clip(session.ConversationId, 128));
  }
  /// A session's project: the one it was started in, else the project holding its folder (deepest folder wins);
  /// Independent is no project.
  public static Project? ProjectFor(string? projectId, string? cwd, IReadOnlyList<TerminalDeck.Core.Projects.Project> projects)
  {
    TerminalDeck.Core.Projects.Project? found = projectId is { Length: > 0 } && projectId != ProjectIdentity.IndependentId ? projects.FirstOrDefault(p => p.Id == projectId) : null;
    if (found is null && cwd is { Length: > 0 })
      found = projects.Where(p => p.Id != ProjectIdentity.IndependentId && !p.Folders.IsDefault)
        .SelectMany(p => p.Folders.Where(f => PhoneSessionGrants.SameOrChild(cwd, f)).Select(f => (p, f.Length)))
        .OrderByDescending(x => x.Length).Select(x => x.p).FirstOrDefault();
    return found is null ? null : new(Clip(found.Id, 128) ?? found.Id, Clip(found.Name, 120) ?? "");
  }
  internal static string? Clip(string? text, int limit) => string.IsNullOrEmpty(text) ? null : text.Length <= limit ? text : text[..limit];

  /// What makes a list put: everything on the rows (a status or a real use moving is a change; at most every 15 s).
  public static string Fingerprint(IEnumerable<Row> rows) =>
    Hex(JsonSerializer.SerializeToUtf8Bytes(rows.OrderBy(r => r.SessionId, StringComparer.Ordinal).ToArray(), Wire));

  // ---- Bytes ----

  public static string Hex(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));
  public static byte[] Gzip(ReadOnlySpan<byte> bytes)
  {
    using var output = new MemoryStream();
    using (var zip = new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true)) zip.Write(bytes);
    return output.ToArray();
  }
  /// The bytes of a gzip member, at most `limit` of them (tests and the read-only view of a raw piece).
  public static byte[]? Gunzip(byte[] bytes, int limit = MaximumRawBytes)
  {
    try
    {
      using var zip = new GZipStream(new MemoryStream(bytes), CompressionMode.Decompress);
      using var output = new MemoryStream();
      var buffer = new byte[81920]; int read;
      while ((read = zip.Read(buffer)) > 0) { output.Write(buffer, 0, read); if (output.Length > limit) return null; }
      return output.ToArray();
    }
    catch (InvalidDataException) { return null; }
  }
  /// A file's size and change time (seconds); null for anything that is not a plain file (a link is not followed).
  public static (long Size, double Mtime)? Look(string? path)
  {
    if (string.IsNullOrEmpty(path)) return null;
    try
    {
      var info = new FileInfo(path);
      if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint) || info.Attributes.HasFlag(FileAttributes.Directory)) return null;
      return (info.Length, (info.LastWriteTimeUtc - DateTime.UnixEpoch).TotalSeconds);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
  /// `count` bytes from `offset` (fewer at the end), read through a handle: a history is never loaded whole.
  public static byte[]? Read(string path, long offset, int count)
  {
    if (count < 0) return null;
    try
    {
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      stream.Seek(Math.Max(0, offset), SeekOrigin.Begin);
      var buffer = new byte[count]; var total = 0;
      while (total < count) { var read = stream.Read(buffer, total, count - total); if (read == 0) break; total += read; }
      return total == count ? buffer : buffer[..total];
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
}

/// One session the side panel lists, in the words the Cloud row needs (the Mac's BackendSessionMeta + status + last use).
/// `Id` is the session's own id on this PC, which survives an app or keeper restart, so it is also its Cloud id and the
/// `tab` its live row carries (the id join).
public sealed record CloudChatsSession(string Id, string Provider, string Cwd, string Title, string Status, long LastUsedAt, long CreatedAt,
  string? ConversationId = null, string? AccountHome = null, string? Login = null, bool Chat = false, string? ProjectId = null, string Kind = "terminal")
{
  /// A terminal session of the keeper. `status`: the phones' word for it (working, input, idle, exited).
  public static CloudChatsSession Terminal(SessionRecord session, string status, long lastUsedAt, string? login = null, string? projectId = null) =>
    new(session.Definition.Id, session.Definition.Provider, session.Definition.Cwd, session.Definition.Title, status, Math.Max(lastUsedAt, session.CreatedAt),
      session.CreatedAt, session.Definition.ConversationId, session.Definition.AccountHome, login, false, projectId);
  /// One of the app's chats.
  public static CloudChatsSession FromChat(ChatRecord chat, string? login = null, string? projectId = null)
  {
    var last = chat.Events.LastOrDefault()?.At.ToUnixTimeMilliseconds() ?? 0;
    var first = chat.Events.FirstOrDefault()?.At.ToUnixTimeMilliseconds() ?? last;
    var status = chat.Ended ? "exited" : chat.Busy || chat.Stopping ? "working" : chat.Problem is not null ? "input" : "idle";
    return new(chat.Definition.Id, chat.Definition.Provider, chat.Definition.Cwd, chat.Definition.Title, status, last, first,
      chat.ConversationId, chat.Definition.AccountHome, login, true, projectId, "chat");
  }
}

/// This PC's `machine` ref while it is signed in (set at Cloud attach, cleared at detach), for the live session list's
/// header so phones and the web match machines by id. Null = not signed in: the field is left out.
public sealed class CloudChatsMachine
{
  public static CloudChatsMachine Shared { get; } = new();
  private volatile string? value;
  public string? Current => value;
  public void Set(string? next) => value = string.IsNullOrEmpty(next) ? null : next;
}

/// Finds each session's history file on this PC: sizes and paths only; a file is opened only to copy what was added.
public sealed class CloudChatsLocator
{
  public IReadOnlyList<string> ClaudeHomes { get; }
  public IReadOnlyList<string> CodexHomes { get; }
  /// Gemini's own folders (`<GEMINI_CLI_HOME>\.gemini`).
  public IReadOnlyList<string> GeminiHomes { get; }
  /// `<data>\chats` (the app's chats) and `<data>\state\hoot.json` (Hoot).
  public string Chats { get; }
  public string HootFile { get; }
  /// Terminal Deck's own AI login folders' parent (`<data>\accounts`): earlier chats.
  public IReadOnlyList<string> OwnRoots { get; }
  private readonly ConcurrentDictionary<string, (string? Path, DateTime At)> codexFound = new(), geminiFound = new();

  public CloudChatsLocator(IReadOnlyList<string> claudeHomes, IReadOnlyList<string> codexHomes, IReadOnlyList<string> geminiHomes, string chats, string hootFile,
    IReadOnlyList<string>? ownRoots = null)
  {
    ClaudeHomes = claudeHomes; CodexHomes = codexHomes; GeminiHomes = geminiHomes; Chats = chats; HootFile = hootFile; OwnRoots = ownRoots ?? [];
  }

  /// This PC's real places: every account home Terminal Deck made (`<data>\accounts\<id>\<ai>`) plus the existing
  /// sign-in's own folders (only the installed app uses those; a test copy has its own sign-ins).
  public static CloudChatsLocator ForWindows(AppDataRoot root, string userProfile)
  {
    var accounts = Path.Combine(root.DirectoryPath, "accounts");
    var ids = Directory.Exists(accounts) ? Directory.EnumerateDirectories(accounts).Where(d => Guid.TryParseExact(Path.GetFileName(d), "N", out _)).ToArray() : [];
    var stable = StableChannel.IsStable(root.DirectoryPath);
    return new(
      [.. ids.Select(d => Path.Combine(d, "claude")), .. stable ? new[] { Path.Combine(userProfile, ".claude") } : []],
      [.. ids.Select(d => Path.Combine(d, "codex")), .. stable ? new[] { Path.Combine(userProfile, ".codex") } : []],
      [.. ids.Select(d => Path.Combine(d, "gemini", ".gemini")), .. stable ? new[] { Path.Combine(userProfile, ".gemini") } : []],
      Path.Combine(root.DirectoryPath, "chats"), Path.Combine(root.DirectoryPath, "state", "hoot.json"), [accounts]);
  }

  /// Each AI login home Terminal Deck made on this PC (never the plain `%USERPROFILE%\.claude`, `.codex`, `.gemini`).
  public IReadOnlyList<string> OwnHomes() => OwnRoots.Where(Directory.Exists).SelectMany(root => Directory.EnumerateDirectories(root)
      .Where(d => !Path.GetFileName(d).StartsWith('.') && !File.GetAttributes(d).HasFlag(FileAttributes.ReparsePoint))
      .SelectMany(d => new[] { Path.Combine(d, "claude"), Path.Combine(d, "codex"), Path.Combine(d, "gemini", ".gemini") }))
    .Where(Directory.Exists).ToArray();

  private static readonly Regex SafeId = new("^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant);
  /// Claude Code's project folder name for a working folder: every character that is not an ASCII letter or digit
  /// becomes "-" (`C:\Users\x\proj` is `C--Users-x-proj`).
  public static string ClaudeFolder(string cwd) => new(cwd.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-').ToArray());

  public CloudChats.Source SourceFor(CloudChatsSession session)
  {
    if (session.Chat)
    {
      if (!Guid.TryParse(session.Id, out var id)) return CloudChats.Source.None;
      var file = Path.Combine(Chats, id.ToString("N"), "chat.json");
      return CloudChats.Look(file) is null ? CloudChats.Source.None : new(Readable: CloudChatsReadable.Format.AppChat, Snap: file, Provider: session.Provider);
    }
    if (session.ConversationId is not { } conversation || !SafeId.IsMatch(conversation)) return CloudChats.Source.None;
    switch (session.Provider)
    {
      case "claude":
        {
          var folder = ClaudeFolder(session.Cwd);
          (string Path, double Mtime)? best = null;
          foreach (var home in ClaudeHomes)
          {
            var file = Path.Combine(home, "projects", folder, conversation + ".jsonl");
            if (CloudChats.Look(file) is { } seen && seen.Mtime >= (best?.Mtime ?? -1)) best = (file, seen.Mtime);
          }
          if (best is not { } raw) return CloudChats.Source.None;
          var side = Path.Combine(Path.ChangeExtension(raw.Path, null), "tool-results");
          var tools = Directory.Exists(side) ? Directory.EnumerateFiles(side).Where(f => !Path.GetFileName(f).StartsWith('.'))
            .OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal).Take(CloudChats.ToolStreamsMax).ToArray() : [];
          return new(raw.Path, tools, CloudChatsReadable.Format.Claude, Provider: "claude");
        }
      case "codex":
        return Cached(codexFound, conversation, () => CodexFile(CodexHomes, conversation)) is { } codex
          ? new(codex, Readable: CloudChatsReadable.Format.Codex, Provider: "codex") : CloudChats.Source.None;
      case "gemini":
        return Cached(geminiFound, conversation, () => GeminiHomes.Select(h => GeminiFile(h, conversation)).FirstOrDefault(f => f is not null)) is { } gemini
          ? new(gemini, Readable: CloudChatsReadable.Format.Gemini, Provider: "gemini") : CloudChats.Source.None;
      default:
        return CloudChats.Source.None;
    }
  }
  /// Hoot's chat on this PC: its saved state (readable copy only; it also holds Hoot's own memory, which is not a chat).
  public CloudChats.Source? HootSource() => CloudChats.Look(HootFile) is null ? null : new(Raw: HootFile, Readable: CloudChatsReadable.Format.Hoot);

  /// Codex names its history `sessions\<y>\<m>\<d>\rollout-<time>-<thread id>.jsonl`.
  public static string? CodexFile(IEnumerable<string> homes, string id)
  {
    foreach (var home in homes)
      foreach (var name in new[] { "sessions", "archived_sessions" })
      {
        var root = Path.Combine(home, name);
        if (!Directory.Exists(root)) continue;
        try
        {
          var hit = Directory.EnumerateFiles(root, "rollout-*" + id + ".jsonl", SearchOption.AllDirectories).FirstOrDefault();
          if (hit is not null) return hit;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
      }
    return null;
  }
  /// Gemini names its chat files `session-<time>-<first 8 of the id>.json` under `tmp\<project>\chats\`.
  public static string? GeminiFile(string home, string id)
  {
    var tmp = Path.Combine(home, "tmp");
    if (!Directory.Exists(tmp)) return null;
    var shortId = id.Length > 8 ? id[..8] : id;
    foreach (var project in Directory.EnumerateDirectories(tmp))
    {
      var chats = Path.Combine(project, "chats");
      if (!Directory.Exists(chats)) continue;
      foreach (var file in Directory.EnumerateFiles(chats, "*.json").Where(f => Path.GetFileName(f).Contains(shortId, StringComparison.Ordinal)))
        if (CloudChats.Read(file, 0, 4_096) is { } head && Encoding.UTF8.GetString(head).Contains(id, StringComparison.Ordinal)) return file;
    }
    return null;
  }
  /// A found file is kept; a miss is looked for again after 10 minutes (the AI may not have written it yet).
  private static string? Cached(ConcurrentDictionary<string, (string? Path, DateTime At)> table, string id, Func<string?> find)
  {
    if (table.TryGetValue(id, out var hit) && (hit.Path is not null || DateTime.UtcNow - hit.At < TimeSpan.FromMinutes(10)))
    {
      if (hit.Path is null) return null;
      if (CloudChats.Look(hit.Path) is not null) return hit.Path;
      table.TryRemove(id, out _);
    }
    var found = find();
    table[id] = (found, DateTime.UtcNow);
    return found;
  }
}

/// What a chats call came back with. A thrown exception is a lost answer.
public sealed record CloudChatsAnswer(int Status, byte[] Data);
public delegate Task<CloudChatsAnswer> CloudChatsSend(string method, string path, byte[] body);

/// The uploader: this PC's list and its sessions' streams, with what the service holds of each, kept beside this
/// identity's sync store so a crash or a quit resumes where it was (`chats\state.json`; the readable copy's open tail in
/// `chats\tails\`). One call at a time.
public sealed partial class CloudChatsUploader
{
  /// One stream of one session, as far as the service holds it (this generation).
  public sealed class Stream
  {
    public int Gen { get; set; } = 1;
    /// Bytes of this stream the service holds.
    public long Length { get; set; }
    /// Of those, bytes in closed pieces, and how many pieces.
    public long Pieced { get; set; }
    public int Pieces { get; set; }
    /// The open tail's parts (raw lengths), oldest first.
    public List<int> Tail { get; set; } = [];
    /// The file this stream copies (`raw`, `tool:`) or reads (`read`); another file starts a new generation.
    public string? Source { get; set; }
    /// `read`: how far the source was read (bytes of a line history; messages of a Gemini file; the last event sequence
    /// of an app chat), the event lines written, the conversation of this generation.
    public long SourceOffset { get; set; }
    public long Events { get; set; }
    public string? Conversation { get; set; }
    /// `raw`/`tool:`: sha256 of the last <= 4 KiB the service holds (a rewound or rewritten file no longer matches).
    public string? TailSha { get; set; }
    public long GrewAt { get; set; }
    public long SeenSize { get; set; }
    public double SeenMtime { get; set; }
    /// `read` of a whole-file history (Gemini, an app chat, Hoot): changed since it was last read through.
    public bool Dirty { get; set; }
    public Stream Copy() { var copy = (Stream)MemberwiseClone(); copy.Tail = [.. Tail]; return copy; }
  }
  public sealed class Session
  {
    public Dictionary<string, Stream> Streams { get; set; } = [];
    public string? SnapSha { get; set; }
    public double SnapMtime { get; set; }
    public long? SnapChangedAt { get; set; }
    /// The service said `binned`: never uploaded again by itself. `NotYours`: another machine owns that id.
    public bool Binned { get; set; }
    public bool NotYours { get; set; }
    public bool NoTools { get; set; }
  }
  public sealed class State
  {
    public Dictionary<string, Session> Sessions { get; set; } = [];
    public string? ListFingerprint { get; set; }
    public long ListAt { get; set; }
    public int Listed { get; set; }
    /// Earlier chats (Terminal Deck's own past sessions on this PC), by their Cloud id.
    public Dictionary<string, Archived> Archive { get; set; } = [];
  }
  public enum Stage { Waiting, Introduced, Closed, Done }
  /// One earlier chat: found on this PC, put in the list ONCE so the service knows its name, project and dates, taken off
  /// the list again at the next list put (so it is a closed session's chat, "Earlier chats"), then copied, then done.
  public sealed class Archived
  {
    public CloudChatsArchive.Found Found { get; set; } = null!;
    public CloudChats.Row Row { get; set; } = null!;
    public Stage Stage { get; set; }
    public long Bytes { get; set; }
    [JsonIgnore] public CloudChats.Listed Listed => new(Row, CloudChatsArchive.SourceOf(Found));
  }
  /// Earlier chats are introduced to the service at most this many per list put.
  public const int ArchiveBatch = 200;

  public sealed record Outcome(string Kind, int Parts = 0, bool List = false)
  {
    /// Nothing grew and the list did not change: nothing was sent.
    public static Outcome Idle { get; } = new("idle");
    public static Outcome Sent(int parts, bool list) => new("sent", parts, list);
    /// The service part is not live (404): silent until the next launch.
    public static Outcome Missing { get; } = new("missing");
    /// Not now (lost connection, 429, `chats_full`): tried again later.
    public static Outcome Later { get; } = new("later");
  }

  private static readonly JsonSerializerOptions StateJson = new() { Converters = { new JsonStringEnumConverter() } };
  private readonly CloudChatsSend send;
  private readonly string? directory;
  private readonly Func<long> clock;
  private readonly SemaphoreSlim gate = new(1, 1);
  public State Saved { get; private set; }
  public bool Missing { get; private set; }
  /// `chats_full` (a cap the service was given): nothing more goes up until the next launch.
  public bool Full { get; private set; }
  private bool headChecked;
  private readonly HashSet<string> needsHead = [];
  /// Streams the service asked to close first (`piece_needed`).
  private readonly HashSet<string> closeSoon = [];
  /// A tick whose answer was lost: sent again, same id and bytes, before anything new.
  private (byte[] Body, List<Plan> Plans, string? List, List<string> Introduce, List<string> Close)? pendingTick;
  /// Files the listed sessions' histories hold (for the status line), by the last look.
  public long SourceBytes { get; private set; }

  public CloudChatsUploader(CloudChatsSend send, string? directory, Func<long>? clock = null)
  {
    this.send = send; this.directory = directory;
    this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    State? loaded = null;
    if (directory is not null && File.Exists(Path.Combine(directory, "state.json")))
      try { loaded = JsonSerializer.Deserialize<State>(File.ReadAllBytes(Path.Combine(directory, "state.json")), StateJson); }
      catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException) { }
    Saved = loaded ?? new State();
  }

  private async Task<T> Locked<T>(Func<Task<T>> work)
  {
    await gate.WaitAsync();
    try { return await work(); }
    finally { gate.Release(); }
  }

  // ---- Wire ----

  private sealed record PartBody(string Session, string Stream, int Gen, long From, int RawLen, string Sha256, string Gz);
  private sealed record TickBody(string TickId, IReadOnlyList<CloudChats.Row>? Sessions, IReadOnlyList<PartBody> Parts);
  private sealed record PieceBody(string Session, string Stream, int Gen, int Index, long RawFrom, int RawLen, string Sha256, string Gz);
  private sealed record SnapBody(string Session, int RawLen, string Sha256, string Gz);

  private abstract record Answer;
  private sealed record Ok(byte[] Data) : Answer;
  private sealed record Refused(int Status, string? Code, byte[] Data) : Answer;
  private sealed record Lost : Answer;

  private async Task<Answer> CallAsync(string method, string path, byte[]? body = null)
  {
    if (Missing) return new Refused(404, "not_found", []);
    CloudChatsAnswer answered;
    try { answered = await send(method, path, body ?? []); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { return new Lost(); }
    if (answered.Status is >= 200 and < 300) return new Ok(answered.Data);
    var code = ErrorCode(answered.Data);
    // The routes are not there yet (or switched off): quiet until the next launch.
    if (answered.Status == 404 && path is "/chats/head" or "/chats/tick" && code is null or "not_found") Missing = true;
    return new Refused(answered.Status, code, answered.Data);
  }
  private static string? ErrorCode(byte[] data)
  {
    try
    {
      using var doc = JsonDocument.Parse(data);
      var root = doc.RootElement;
      if (root.ValueKind != JsonValueKind.Object) return null;
      if (root.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object) return CloudChatsReadable.Str(e, "code");
      return CloudChatsReadable.Str(root, "code");
    }
    catch (JsonException) { return null; }
  }
  private static JsonElement? Json(byte[] data)
  {
    try { using var doc = JsonDocument.Parse(data); return doc.RootElement.Clone(); }
    catch (JsonException) { return null; }
  }
  private static long? Long(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : null;
  private static bool True(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

  private void Save()
  {
    if (directory is null) return;
    try
    {
      Directory.CreateDirectory(directory);
      var path = Path.Combine(directory, "state.json"); var temporary = path + "." + Guid.NewGuid().ToString("N");
      File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(Saved, StateJson));
      File.Move(temporary, path, true);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }

  // ---- The readable copy's open tail (kept on disk until it is closed into a piece) ----

  private string? Spool(string session) => directory is null ? null : Path.Combine(directory, "tails", CloudChats.Hex(Encoding.UTF8.GetBytes(session))[..32] + ".read");
  private void SpoolAppend(string session, byte[] bytes)
  {
    if (Spool(session) is not { } file) return;
    try { Directory.CreateDirectory(Path.GetDirectoryName(file)!); using var stream = new FileStream(file, FileMode.Append, FileAccess.Write); stream.Write(bytes); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }
  private void SpoolClear(string session)
  {
    if (Spool(session) is { } file) try { File.Delete(file); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }

  // ---- Resume ----

  /// Once per launch: what the service holds of this machine's streams. A stream it holds differently is taken as the
  /// service has it (a crash between its answer and this PC's save); a readable copy that differs starts again.
  private async Task ResumeAsync()
  {
    if (headChecked || Missing) return;
    if (await CallAsync("GET", "/chats/head") is not Ok ok) return;
    headChecked = true;
    Adopt(ok.Data);
  }
  private void Adopt(byte[] data)
  {
    if (Json(data) is not { } head || !head.TryGetProperty("sessions", out var list) || list.ValueKind != JsonValueKind.Array) return;
    foreach (var held in list.EnumerateArray())
    {
      if (CloudChatsReadable.Str(held, "session") is not { } id) continue;
      var session = Saved.Sessions.GetValueOrDefault(id) ?? new Session();
      if (True(held, "binned")) session.Binned = true;
      if (held.TryGetProperty("streams", out var streams) && streams.ValueKind == JsonValueKind.Object)
        foreach (var named in streams.EnumerateObject())
        {
          var stream = named.Value;
          var mine = session.Streams.GetValueOrDefault(named.Name) ?? new Stream();
          var gen = (int)(Long(stream, "gen") ?? mine.Gen); var length = Long(stream, "length") ?? 0;
          var tail = stream.TryGetProperty("tailParts", out var t) && t.ValueKind == JsonValueKind.Array ? t.EnumerateArray().Select(p => p.GetInt32()).ToList() : [];
          var pieces = (int)(Long(stream, "pieces") ?? 0);
          if (gen == mine.Gen && length == mine.Length && tail.SequenceEqual(mine.Tail) && pieces == mine.Pieces) continue;
          if (named.Name == "read")
          {
            // Derived from the history: written again from its start in a new generation.
            mine = new Stream { Gen = Math.Max(gen, session.Streams.GetValueOrDefault("read")?.Gen ?? 1) + 1 };
            SpoolClear(id);
          }
          else
          {
            mine.Gen = gen; mine.Length = length; mine.Pieced = Long(stream, "pieced") ?? 0; mine.Pieces = pieces; mine.Tail = tail;
            mine.TailSha = mine.Source is { } source ? TailSha(source, length) : null;
          }
          session.Streams[named.Name] = mine;
        }
      Saved.Sessions[id] = session;
    }
    Save();
  }
  private async Task RefreshHeadAsync(string session)
  {
    if (await CallAsync("GET", "/chats/head?session=" + Uri.EscapeDataString(session)) is not Ok ok) return;
    needsHead.Remove(session);
    Adopt(ok.Data);
  }
  private static string? TailSha(string path, long length)
  {
    var start = Math.Max(0, length - CloudChats.TailCheckBytes);
    return CloudChats.Read(path, start, (int)(length - start)) is { } bytes && bytes.Length == length - start ? CloudChats.Hex(bytes) : null;
  }

  // ---- Planning one stream ----

  private sealed record Plan(string Session, string Stream, int Gen, long From, byte[] Bytes, long? SourceOffset = null, int Events = 0, string? Conversation = null);
  private enum LookKind { Nothing, Part, CatchUp, CloseNow }
  private readonly record struct LookResult(LookKind Kind, Plan? Plan = null)
  {
    public static LookResult Nothing => new(LookKind.Nothing);
  }

  private Stream StreamOf(string session, string name) => Saved.Sessions.GetValueOrDefault(session)?.Streams.GetValueOrDefault(name)?.Copy() ?? new Stream();
  private void SetStream(string session, string name, Stream value)
  {
    var held = Saved.Sessions.GetValueOrDefault(session) ?? new Session();
    held.Streams[name] = value;
    Saved.Sessions[session] = held;
  }
  private Session SessionOf(string id) => Saved.Sessions.TryGetValue(id, out var s) ? s : Saved.Sessions[id] = new Session();
  /// A new generation from byte 0 (the file shrank, was rewound, rewritten or replaced). Older ones stay in the Cloud.
  private void Restart(string session, string name, string? source, int above = 0)
  {
    SetStream(session, name, new Stream { Gen = Math.Max(StreamOf(session, name).Gen, above) + 1, Source = source, Dirty = true });
    if (name == "read") SpoolClear(session);
  }

  /// A copied file (`raw`, `tool:`): what was added since the service's length, when it is little enough for a tick.
  private LookResult LookFile(string session, string name, string path, long quietMs, long now)
  {
    if (CloudChats.Look(path) is not { } seen) return LookResult.Nothing;
    var held = StreamOf(session, name);
    if (held.Source != path)
    {
      if (held.Source is not null) Restart(session, name, path);
      else
      {
        // First look, or what the service holds was taken over after this PC's own record was lost: the file is checked
        // against it by its tail, below.
        held.Source = path;
        if (held.Length > 0) held.TailSha = TailSha(path, held.Length);
        SetStream(session, name, held);
      }
      held = StreamOf(session, name);
    }
    if (seen.Size != held.SeenSize || seen.Mtime != held.SeenMtime)
    {
      held.SeenSize = seen.Size; held.SeenMtime = seen.Mtime; held.GrewAt = now; SetStream(session, name, held);
      if (seen.Size < held.Length || held.Length > 0 && TailSha(path, held.Length) != held.TailSha)
      {
        Restart(session, name, path);
        held = StreamOf(session, name); held.SeenSize = seen.Size; held.SeenMtime = seen.Mtime; held.GrewAt = now;
        SetStream(session, name, held);
      }
    }
    var backlog = seen.Size - held.Length;
    if (backlog <= 0) return LookResult.Nothing;
    if (quietMs > 0 && now - held.GrewAt < quietMs) return LookResult.Nothing;
    if (backlog > CloudChats.PartRawBytes) return new(held.Tail.Count == 0 ? LookKind.CatchUp : LookKind.CloseNow);
    if (CloudChats.Read(path, held.Length, (int)backlog) is not { } bytes || bytes.Length != backlog) return LookResult.Nothing;
    return new(LookKind.Part, new Plan(session, name, held.Gen, held.Length, bytes));
  }

  /// The readable copy: the event lines for what was added to the history since it was last read.
  private LookResult LookRead(string session, CloudChats.Listed listed, long now, bool catchUp)
  {
    if (listed.Source.Readable is not { } format) return LookResult.Nothing;
    var file = format == CloudChatsReadable.Format.AppChat ? listed.Source.Snap : listed.Source.Raw;
    if (file is null || CloudChats.Look(file) is not { } seen) return LookResult.Nothing;
    var held = StreamOf(session, "read");
    if (held.Source != file)
    {
      if (held.Source is not null || held.Length > 0) Restart(session, "read", file); else { held.Source = file; SetStream(session, "read", held); }
      held = StreamOf(session, "read");
    }
    var moved = seen.Size != held.SeenSize || seen.Mtime != held.SeenMtime;
    if (moved) { held.SeenSize = seen.Size; held.SeenMtime = seen.Mtime; held.GrewAt = now; SetStream(session, "read", held); }
    const int limit = CloudChats.ReadPieceBytes;
    var provider = listed.Source.Provider ?? listed.Row.Ai ?? "claude";
    var conversation = listed.Row.ConversationId ?? session;
    switch (format)
    {
      case CloudChatsReadable.Format.Claude or CloudChatsReadable.Format.Codex:
        {
          if (seen.Size < held.SourceOffset) { Restart(session, "read", file); held = StreamOf(session, "read"); }
          var backlog = seen.Size - held.SourceOffset;
          if (backlog <= 0) return LookResult.Nothing;
          if (!catchUp && backlog > CloudChats.PartRawBytes) return new(held.Tail.Count == 0 ? LookKind.CatchUp : LookKind.CloseNow);
          if (catchUp && held.Tail.Count > 0) return new(LookKind.CloseNow);
          // Up to 64 MiB of history read per look (8 MiB windows) to find about one piece of readable lines.
          var lines = new MemoryStream(); var events = 0; var offset = held.SourceOffset; long scanned = 0;
          const int window = 8 * 1_048_576;
          while (offset < seen.Size && lines.Length < limit && scanned < 64L * 1_048_576)
          {
            if (CloudChats.Read(file, offset, (int)Math.Min(window, seen.Size - offset)) is not { Length: > 0 } bytes) break;
            var quiet = now - (long)(seen.Mtime * 1000) >= CloudChats.LineQuietMs && offset + bytes.Length >= seen.Size;
            var made = CloudChatsReadable.Read(bytes, format, conversation, provider, held.Events + events + 1, limit - (int)lines.Length, quiet);
            if (made.Consumed == 0)
            {
              // One line longer than the window (a huge tool result): passed over, it is never a message.
              if (bytes.Length != window || NextLine(file, offset + bytes.Length, seen.Size) is not { } skip) break;
              scanned += skip - offset; offset = skip; continue;
            }
            lines.Write(made.Lines); events += made.Events;
            offset += made.Consumed; scanned += made.Consumed;
          }
          if (lines.Length == 0)
          {
            // Nothing readable in what was added (tool traffic): read on, nothing to send.
            if (offset != held.SourceOffset) { held = StreamOf(session, "read"); held.SourceOffset = offset; SetStream(session, "read", held); }
            return LookResult.Nothing;
          }
          return new(LookKind.Part, new Plan(session, "read", held.Gen, held.Length, lines.ToArray(), offset, events, conversation));
        }
      default:
        {
          if (moved) { held = StreamOf(session, "read"); held.Dirty = true; SetStream(session, "read", held); }
          if (!held.Dirty) return LookResult.Nothing;
          void Settled() { var done = StreamOf(session, "read"); done.Dirty = false; SetStream(session, "read", done); }
          if (seen.Size > 512L * 1_048_576 || CloudChats.Read(file, 0, (int)seen.Size) is not { } data) { Settled(); return LookResult.Nothing; }
          if (format == CloudChatsReadable.Format.Gemini)
          {
            if (CloudChatsReadable.Gemini(data) is not { } parsed) { Settled(); return LookResult.Nothing; }
            var gem = parsed.Conversation.Length == 0 ? conversation : parsed.Conversation;
            if (parsed.Messages.Count < held.SourceOffset || held.Conversation is not null && held.Conversation != gem) { Restart(session, "read", file); held = StreamOf(session, "read"); }
            var gemLines = new MemoryStream(); var gemEvents = 0;
            foreach (var message in parsed.Messages.Skip((int)held.SourceOffset))
            {
              var line = CloudChatsReadable.Line(message, gem, held.Events + gemEvents + 1, "gemini");
              if (gemLines.Length + line.Length > CloudChats.PartRawBytes) break;
              gemLines.Write(line); gemEvents++;
            }
            if (gemEvents == 0) { Settled(); return LookResult.Nothing; }
            return new(LookKind.Part, new Plan(session, "read", held.Gen, held.Length, gemLines.ToArray(), held.SourceOffset + gemEvents, gemEvents, gem));
          }
          var own = format == CloudChatsReadable.Format.Hoot ? CloudChatsReadable.Hoot(data) : CloudChatsReadable.AppChat(data);
          if (own is not { } chat) { Settled(); return LookResult.Nothing; }
          var newest = chat.Events.Count == 0 ? 0 : chat.Events[^1].Sequence;
          if (newest < held.SourceOffset || held.Conversation is not null && held.Conversation != chat.Conversation) { Restart(session, "read", file); held = StreamOf(session, "read"); }
          var ownLines = new MemoryStream(); var ownEvents = 0; var last = held.SourceOffset;
          foreach (var (sequence, line) in chat.Events.Where(e => e.Sequence > held.SourceOffset))
          {
            if (ownLines.Length + line.Length > CloudChats.PartRawBytes) break;
            ownLines.Write(line); ownEvents++; last = sequence;
          }
          if (ownEvents == 0) { Settled(); return LookResult.Nothing; }
          return new(LookKind.Part, new Plan(session, "read", held.Gen, held.Length, ownLines.ToArray(), last, ownEvents, chat.Conversation));
        }
    }
  }
  /// The byte after the next newline at or after `from` (null: none before `end`).
  private static long? NextLine(string path, long from, long end)
  {
    var offset = from;
    while (offset < end)
    {
      if (CloudChats.Read(path, offset, (int)Math.Min(1_048_576, end - offset)) is not { Length: > 0 } bytes) return null;
      var newline = Array.IndexOf(bytes, (byte)'\n');
      if (newline >= 0) return offset + newline + 1;
      offset += bytes.Length;
    }
    return null;
  }

  /// A stream's accepted bytes: the service holds them now.
  private void Commit(Plan plan, long? have)
  {
    var held = StreamOf(plan.Session, plan.Stream);
    if (held.Gen != plan.Gen || held.Length != plan.From) return;
    held.Length = have ?? plan.From + plan.Bytes.Length;
    held.Tail.Add(plan.Bytes.Length);
    if (plan.Stream == "read")
    {
      SpoolAppend(plan.Session, plan.Bytes);
      if (plan.SourceOffset is { } offset) held.SourceOffset = offset;
      held.Events += plan.Events;
      if (plan.Conversation is not null) held.Conversation = plan.Conversation;
    }
    else
    {
      var tail = plan.Bytes.AsSpan(Math.Max(0, plan.Bytes.Length - CloudChats.TailCheckBytes));
      held.TailSha = tail.Length == CloudChats.TailCheckBytes || plan.From == 0 ? CloudChats.Hex(tail) : held.Source is { } source ? TailSha(source, held.Length) : null;
    }
    held.GrewAt = clock();
    SetStream(plan.Session, plan.Stream, held);
  }

  // ---- The live tick ----

  /// One look at every listed session (about every 30 s): ONE call carries this PC's list when it changed (at most every
  /// 15 s, and once at launch) and every stream's new bytes; then tails due are closed and quiet app chats' files go up.
  /// Nothing grew and the list is the same: nothing is sent.
  public Task<Outcome> RoundAsync(IReadOnlyList<CloudChats.Listed> listed) => Locked(() => Round(listed));
  private async Task<Outcome> Round(IReadOnlyList<CloudChats.Listed> listed)
  {
    if (Missing) return Outcome.Missing;
    if (Full) return Outcome.Later;
    await ResumeAsync();
    if (Missing) return Outcome.Missing;
    foreach (var session in needsHead.ToArray()) await RefreshHeadAsync(session);
    var now = clock();
    if (pendingTick is { } pending)
    {
      // The last tick's answer was lost: the same tick again (the service answers it once, never stores twice).
      pendingTick = null;
      return await SendTickAsync(pending.Body, pending.Plans, pending.List, pending.Introduce, pending.Close);
    }
    // Earlier chats waiting to be introduced ride along with this PC's list, a batch at a time; the ones introduced by
    // the last put are left out of this one, which makes them closed sessions' chats on the service.
    var introduce = Saved.Archive.Values.Where(a => a.Stage == Stage.Waiting).OrderByDescending(a => a.Row.LastUsedAt).Take(ArchiveBatch).Select(a => a.Row).ToList();
    var closing = Saved.Archive.Where(a => a.Value.Stage == Stage.Introduced).Select(a => a.Key).ToList();
    var rows = listed.Select(l => l.Row).Concat(introduce).ToList();
    var fingerprint = CloudChats.Fingerprint(rows);
    var listDue = fingerprint != Saved.ListFingerprint && now - Saved.ListAt >= CloudChats.ListEveryMs;
    var plans = new List<(Plan Plan, string Gz)>(); var closeNow = new List<(string, string)>(); var budget = CloudChats.TickBodyBytes;
    long total = 0;
    foreach (var item in listed)
    {
      var id = item.Row.SessionId;
      var session = Saved.Sessions.GetValueOrDefault(id) ?? new Session();
      if (session.Binned || session.NotYours) continue;
      var jobs = new List<(string Name, string? Path, long Quiet)>();
      if (item.Source.Readable is not null) jobs.Add(("read", null, 0));
      if (item.Source.Raw is { } raw && item.Source.Readable != CloudChatsReadable.Format.Hoot)
      {
        total += CloudChats.Look(raw)?.Size ?? 0;
        jobs.Add(("raw", raw, item.Source.Readable == CloudChatsReadable.Format.Gemini ? CloudChats.GeminiQuietMs : 0));
      }
      if (!session.NoTools) foreach (var tool in item.Source.ToolFiles) jobs.Add(("tool:" + Path.GetFileName(tool), tool, 0));
      foreach (var (name, path, quiet) in jobs)
      {
        var look = path is null ? LookRead(id, item, now, catchUp: false) : LookFile(id, name, path, quiet, now);
        switch (look.Kind)
        {
          case LookKind.Part:
            // Each part gzip-compressed on its own; the body stays under the service's 8 MiB a call.
            var gz = Convert.ToBase64String(CloudChats.Gzip(look.Plan!.Bytes));
            if (gz.Length + 512 > budget) continue;
            budget -= gz.Length + 512;
            plans.Add((look.Plan, gz));
            break;
          case LookKind.CloseNow: closeNow.Add((id, name)); break;
        }
      }
    }
    SourceBytes = total;
    var outcome = Outcome.Idle;
    if (plans.Count > 0 || listDue)
    {
      var parts = plans.Select(p => new PartBody(p.Plan.Session, p.Plan.Stream, p.Plan.Gen, p.Plan.From, p.Plan.Bytes.Length, CloudChats.Hex(p.Plan.Bytes), p.Gz)).ToArray();
      var body = JsonSerializer.SerializeToUtf8Bytes(new TickBody(Guid.NewGuid().ToString("D"), listDue ? rows : null, parts), CloudChats.Wire);
      outcome = await SendTickAsync(body, plans.Select(p => p.Plan).ToList(), listDue ? fingerprint : null, listDue ? introduce.Select(r => r.SessionId).ToList() : [], listDue ? closing : []);
      if (outcome == Outcome.Missing) return Outcome.Missing;
    }
    Saved.Listed = listed.Count;
    // Tails due: 4 MiB raw (1 MiB readable), 64 parts, 10 minutes without growth, or a big addition waiting.
    foreach (var item in listed)
    {
      var id = item.Row.SessionId;
      foreach (var (name, held) in (Saved.Sessions.GetValueOrDefault(id)?.Streams ?? new Dictionary<string, Stream>()).ToArray())
      {
        if (held.Tail.Count == 0) continue;
        var size = held.Tail.Sum();
        var due = size >= (name == "read" ? CloudChats.ReadPieceBytes : CloudChats.RawPieceBytes) || held.Tail.Count >= CloudChats.TailPartsMax
          || now - held.GrewAt >= CloudChats.QuietCloseMs || closeNow.Contains((id, name)) || closeSoon.Contains(Key(id, name));
        if (due && await CloseAsync(id, name)) closeSoon.Remove(Key(id, name));
      }
    }
    // Quiet app chats: their saved file, 2 minutes after it last changed.
    foreach (var item in listed.Where(i => i.Source.Snap is not null)) await SnapAsync(item, now);
    Save();
    return outcome;
  }
  private static string Key(string session, string stream) => session + "|" + stream;

  private async Task<Outcome> SendTickAsync(byte[] data, List<Plan> plans, string? list, List<string> introduce, List<string> close)
  {
    switch (await CallAsync("POST", "/chats/tick", data))
    {
      case Lost:
        pendingTick = (data, plans, list, introduce, close);
        return Outcome.Later;
      case Refused refused:
        if (refused.Status == 404) return Outcome.Missing;
        if (refused.Code == "chats_full") Full = true;
        return Outcome.Later;
      case Ok ok:
        var decoded = Json(ok.Data);
        if (list is not null)
        {
          Saved.ListFingerprint = list; Saved.ListAt = clock();
          var notYours = decoded is { } d && d.TryGetProperty("sessions", out var s) && s.ValueKind == JsonValueKind.Object && s.TryGetProperty("notYours", out var n)
            && n.ValueKind == JsonValueKind.Array ? n.EnumerateArray().Select(x => x.GetString()).OfType<string>().ToList() : [];
          foreach (var id in notYours) SessionOf(id).NotYours = true;
          foreach (var id in introduce) if (Saved.Archive.TryGetValue(id, out var a)) a.Stage = Stage.Introduced;
          foreach (var id in close) if (Saved.Archive.TryGetValue(id, out var a) && a.Stage == Stage.Introduced) a.Stage = Stage.Closed;
          foreach (var id in notYours) if (Saved.Archive.TryGetValue(id, out var a)) a.Stage = Stage.Done;
        }
        if (decoded is { } answer && answer.TryGetProperty("parts", out var answered) && answered.ValueKind == JsonValueKind.Array)
          foreach (var part in answered.EnumerateArray())
          {
            var plan = plans.FirstOrDefault(p => p.Session == CloudChatsReadable.Str(part, "session") && p.Stream == CloudChatsReadable.Str(part, "stream"));
            if (plan is null) continue;
            if (True(part, "ok")) { Commit(plan, Long(part, "have")); continue; }
            switch (CloudChatsReadable.Str(part, "code"))
            {
              case "chat_offset" or "old_gen":
                if (plan.Stream == "read") Restart(plan.Session, "read", StreamOf(plan.Session, "read").Source, (int)(Long(part, "gen") ?? 0));
                else needsHead.Add(plan.Session);
                break;
              case "binned": SessionOf(plan.Session).Binned = true; break;
              // The session moved to another machine (Switch, not on this PC yet): nothing more of it goes up from here.
              case "not_yours": SessionOf(plan.Session).NotYours = true; break;
              case "too_many_streams": SessionOf(plan.Session).NoTools = true; break;
              case "piece_needed": closeSoon.Add(Key(plan.Session, plan.Stream)); break;
              case "chats_full": Full = true; break;
              default: break; // bad_bytes or a code this build does not know: the same bytes are planned again next tick
            }
          }
        Save();
        return Outcome.Sent(plans.Count, list is not null);
    }
    return Outcome.Later;
  }

  // ---- Pieces ----

  /// Closes a stream's open tail into ONE piece: the tail's bytes again, read from the history (`raw`, `tool:`) or from
  /// the kept tail (`read`). The service then drops the covered tail parts.
  private async Task<bool> CloseAsync(string session, string name)
  {
    var held = StreamOf(session, name);
    var size = held.Tail.Sum();
    if (size <= 0) return false;
    byte[]? bytes;
    if (name == "read")
    {
      bytes = Spool(session) is { } file && File.Exists(file) ? File.ReadAllBytes(file) : null;
      // The kept tail is gone (a cleaned folder): the readable copy starts again.
      if (bytes?.Length != size) { Restart(session, "read", held.Source); return false; }
    }
    else
    {
      bytes = held.Source is { } source ? CloudChats.Read(source, held.Pieced, size) : null;
      if (bytes?.Length != size) { needsHead.Add(session); return false; }
    }
    return await PieceAsync(session, name, held, bytes, null);
  }

  /// One piece call. `extra`: a catch-up piece (no tail), with what the source stands at after it.
  private async Task<bool> PieceAsync(string session, string name, Stream held, byte[] bytes, Plan? extra)
  {
    if (bytes.Length > CloudChats.MaximumRawBytes) return false;
    var body = JsonSerializer.SerializeToUtf8Bytes(new PieceBody(session, name, held.Gen, held.Pieces, held.Pieced, bytes.Length, CloudChats.Hex(bytes),
      Convert.ToBase64String(CloudChats.Gzip(bytes))), CloudChats.Wire);
    var answer = await CallAsync("POST", "/chats/piece", body);
    var now = StreamOf(session, name);
    if (now.Gen != held.Gen || now.Pieces != held.Pieces || now.Pieced != held.Pieced) return false;
    switch (answer)
    {
      case Ok ok:
        var decoded = Json(ok.Data) ?? default;
        now.Pieced = Long(decoded, "pieced") ?? held.Pieced + bytes.Length;
        now.Pieces = Long(decoded, "index") is { } index ? (int)index + 1 : held.Pieces + 1;
        if (extra is not null)
        {
          // A catch-up piece: it appended (no tail existed).
          now.Length = Long(decoded, "have") ?? now.Pieced;
          if (extra.SourceOffset is { } offset) now.SourceOffset = offset;
          now.Events += extra.Events;
          if (extra.Conversation is not null) now.Conversation = extra.Conversation;
          if (name != "read") now.TailSha = CloudChats.Hex(bytes.AsSpan(Math.Max(0, bytes.Length - CloudChats.TailCheckBytes)));
        }
        else
        {
          now.Tail = [];
          if (name == "read") SpoolClear(session);
        }
        SetStream(session, name, now);
        Save();
        return true;
      case Refused refused:
        switch (refused.Code)
        {
          case "binned": SessionOf(session).Binned = true; break;
          case "not_yours": SessionOf(session).NotYours = true; break;
          case "chats_full": Full = true; break;
          case "piece_boundary" or "piece_mismatch" or "chat_offset" or "old_gen":
            if (name == "read") Restart(session, "read", now.Source); else needsHead.Add(session);
            break;
        }
        Save();
        return false;
      default:
        return false;
    }
  }

  // ---- Catch-up (old histories, in the background) ----

  /// ONE catch-up piece: the readable copies of every listed session first, then the histories themselves, newest used
  /// first. The caller waits 2 s between steps, at background priority. False: nothing is left to catch up.
  public Task<bool> CatchUpStepAsync(IReadOnlyList<CloudChats.Listed> listed, bool earlier = true) => Locked(() => CatchUpStep(listed, earlier));
  private async Task<bool> CatchUpStep(IReadOnlyList<CloudChats.Listed> listed, bool earlier)
  {
    if (Missing || Full || !headChecked) return false;
    var now = clock();
    var order = listed.OrderByDescending(l => l.Row.LastUsedAt).ToList();
    foreach (var item in order.Where(i => i.Source.Readable is CloudChatsReadable.Format.Claude or CloudChatsReadable.Format.Codex))
    {
      var id = item.Row.SessionId;
      if (!Saved.Sessions.TryGetValue(id, out var session) || session.Binned || session.NotYours || item.Source.Raw is not { } file || CloudChats.Look(file) is not { } seen) continue;
      var held = StreamOf(id, "read");
      if (held.Source != file || seen.Size - held.SourceOffset <= CloudChats.PartRawBytes) continue;
      var before = held.SourceOffset;
      var look = LookRead(id, item, now, catchUp: true);
      switch (look.Kind)
      {
        case LookKind.Part: return await PieceAsync(id, "read", StreamOf(id, "read"), look.Plan!.Bytes, look.Plan);
        case LookKind.CloseNow: return await CloseAsync(id, "read");
        case LookKind.Nothing:
          // Read on through tool traffic (nothing to send); the next step goes on from there.
          if (StreamOf(id, "read").SourceOffset != before) return true;
          break;
      }
    }
    foreach (var item in order)
    {
      var id = item.Row.SessionId;
      if (!Saved.Sessions.TryGetValue(id, out var session) || session.Binned || session.NotYours) continue;
      var files = new List<(string Name, string Path)>();
      if (item.Source.Raw is { } raw && item.Source.Readable is not (CloudChatsReadable.Format.Gemini or CloudChatsReadable.Format.Hoot)) files.Add(("raw", raw));
      if (!session.NoTools) foreach (var tool in item.Source.ToolFiles) files.Add(("tool:" + Path.GetFileName(tool), tool));
      foreach (var (name, path) in files)
      {
        var held = StreamOf(id, name);
        if (held.Source != path || CloudChats.Look(path) is not { } seen || seen.Size - held.Length <= CloudChats.PartRawBytes) continue;
        if (held.Tail.Count > 0) return await CloseAsync(id, name);
        if (CloudChats.Read(path, held.Length, CloudChats.RawPieceBytes) is not { } bytes || bytes.Length != CloudChats.RawPieceBytes) continue;
        // The tail check needs the length the service holds to keep matching the file.
        return await PieceAsync(id, name, held, bytes, new Plan(id, name, held.Gen, held.Length, []));
      }
    }
    // Then the earlier chats (Terminal Deck's own past sessions), newest first, once each is a closed session's.
    if (!earlier) return false;
    foreach (var entry in Saved.Archive.Values.Where(a => a.Stage == Stage.Closed).OrderByDescending(a => a.Row.LastUsedAt).ToList())
    {
      if (await ArchivedStepAsync(entry.Listed) is { } sent) return sent;
      entry.Stage = Stage.Done;
      Save();
    }
    return false;
  }

  /// One piece of an earlier chat: its readable copy first, then the history; the whole history goes as pieces (no tick,
  /// it does not grow any more), the last one shorter. Null: nothing left of it.
  private async Task<bool?> ArchivedStepAsync(CloudChats.Listed item)
  {
    var id = item.Row.SessionId; var now = clock();
    var session = Saved.Sessions.GetValueOrDefault(id) ?? new Session();
    if (session.Binned || session.NotYours) return null;
    if (item.Source.Readable is not null)
    {
      var before = StreamOf(id, "read");
      var look = LookRead(id, item, now, catchUp: true);
      switch (look.Kind)
      {
        case LookKind.Part: return await PieceAsync(id, "read", StreamOf(id, "read"), look.Plan!.Bytes, look.Plan);
        case LookKind.CloseNow: return await CloseAsync(id, "read");
        case LookKind.Nothing:
          var after = StreamOf(id, "read");
          if (after.SourceOffset != before.SourceOffset || after.Gen != before.Gen) return true;
          break;
      }
    }
    if (item.Source.Raw is { } raw)
    {
      var look = LookFile(id, "raw", raw, 0, now);
      switch (look.Kind)
      {
        case LookKind.Part: return await PieceAsync(id, "raw", StreamOf(id, "raw"), look.Plan!.Bytes, look.Plan);
        case LookKind.CatchUp:
          var held = StreamOf(id, "raw");
          if (CloudChats.Read(raw, held.Length, CloudChats.RawPieceBytes) is not { } bytes || bytes.Length != CloudChats.RawPieceBytes) return false;
          return await PieceAsync(id, "raw", held, bytes, new Plan(id, "raw", held.Gen, held.Length, []));
        case LookKind.CloseNow: return await CloseAsync(id, "raw");
      }
    }
    if (item.Source.Snap is not null && Saved.Sessions.GetValueOrDefault(id)?.SnapSha is null) return await SnapNowAsync(item);
    return null;
  }

  /// Earlier chats found on this PC: each new one (by its file) gets its Cloud id and waits to be introduced.
  /// `salt`: this machine's own id, so two machines never give one id to two histories.
  public Task AddArchiveAsync(IReadOnlyList<CloudChatsArchive.Found> found, string salt, IReadOnlyList<TerminalDeck.Core.Projects.Project> projects) => Locked(() =>
  {
    var known = Skip();
    foreach (var item in found.Where(f => !known.Contains(f.Path)))
    {
      var id = "hist-" + CloudChats.Hex(Encoding.UTF8.GetBytes(salt + "\n" + item.Path))[..24];
      if (Saved.Archive.ContainsKey(id)) continue;
      Saved.Archive[id] = new Archived { Found = item, Row = CloudChatsArchive.RowFor(item, id, projects), Stage = Stage.Waiting, Bytes = CloudChats.Look(item.Path)?.Size ?? 0 };
    }
    Save();
    return Task.FromResult(true);
  });
  /// Files already copied (any stream's source) or already known as earlier chats: a scan passes them over.
  public Task<HashSet<string>> ArchiveSkipAsync() => Locked(() => Task.FromResult(Skip()));
  private HashSet<string> Skip()
  {
    var paths = new HashSet<string>(Saved.Archive.Values.Select(a => a.Found.Path), StringComparer.OrdinalIgnoreCase);
    foreach (var session in Saved.Sessions.Values) foreach (var stream in session.Streams.Values) if (stream.Source is { } source) paths.Add(source);
    return paths;
  }

  // ---- Snapshots of the app's chats ----

  /// Runtime fields of a saved chat (busy, the delivery queue, the worker's place) stay on this PC.
  public static readonly IReadOnlySet<string> RuntimeKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    { "busy", "activeClientId", "waitingSince", "stopping", "workerSequence", "messages" };
  /// Removes only top-level runtime fields of a JSON object; anything else is returned byte-identical.
  public static byte[] Neutralise(byte[] bytes)
  {
    try
    {
      if (JsonNode.Parse(bytes) is not JsonObject o) return bytes;
      var drop = o.Select(p => p.Key).Where(RuntimeKeys.Contains).ToArray();
      if (drop.Length == 0) return bytes;
      foreach (var key in drop) o.Remove(key);
      return JsonSerializer.SerializeToUtf8Bytes(o);
    }
    catch (JsonException) { return bytes; }
  }

  private async Task SnapAsync(CloudChats.Listed item, long now)
  {
    var id = item.Row.SessionId;
    var session = SessionOf(id);
    if (item.Source.Snap is not { } file || CloudChats.Look(file) is not { } seen || session.Binned || session.NotYours) return;
    if (seen.Mtime != session.SnapMtime) { session.SnapMtime = seen.Mtime; session.SnapChangedAt = now; return; }
    if (session.SnapChangedAt is not { } changed || now - changed < CloudChats.SnapQuietMs || seen.Size > CloudChats.MaximumRawBytes * 4L
      || CloudChats.Read(file, 0, (int)seen.Size) is not { } raw) return;
    var bytes = Neutralise(raw);
    var sha = CloudChats.Hex(bytes);
    if (sha == session.SnapSha) { session.SnapChangedAt = null; return; }
    // Bigger than one call: the readable copy carries it; the saved file is not sent.
    var gz = bytes.Length <= CloudChats.MaximumRawBytes ? CloudChats.Gzip(bytes) : null;
    if (gz is null || gz.Length > 6 * 1_048_576) { session.SnapChangedAt = null; return; }
    var body = JsonSerializer.SerializeToUtf8Bytes(new SnapBody(id, bytes.Length, sha, Convert.ToBase64String(gz)), CloudChats.Wire);
    switch (await CallAsync("POST", "/chats/snap", body))
    {
      case Ok: session.SnapSha = sha; session.SnapChangedAt = null; break;
      case Refused refused:
        if (refused.Code == "binned") session.Binned = true;
        if (refused.Code == "not_yours") session.NotYours = true;
        if (refused.Code == "chats_full") Full = true;
        break;
    }
  }

  /// An earlier app chat's saved file, at once (it is quiet by now). True when something was done with it.
  private async Task<bool> SnapNowAsync(CloudChats.Listed item)
  {
    var id = item.Row.SessionId;
    if (item.Source.Snap is not { } file || CloudChats.Look(file) is not { } seen || seen.Size > CloudChats.MaximumRawBytes * 4L
      || CloudChats.Read(file, 0, (int)seen.Size) is not { } raw) return false;
    var bytes = Neutralise(raw);
    var sha = CloudChats.Hex(bytes);
    var gz = bytes.Length <= CloudChats.MaximumRawBytes ? CloudChats.Gzip(bytes) : null;
    if (gz is null || gz.Length > 6 * 1_048_576) { SessionOf(id).SnapSha = sha; Save(); return true; }
    var body = JsonSerializer.SerializeToUtf8Bytes(new SnapBody(id, bytes.Length, sha, Convert.ToBase64String(gz)), CloudChats.Wire);
    if (await CallAsync("POST", "/chats/snap", body) is not Ok) return false;
    SessionOf(id).SnapSha = sha; Save();
    return true;
  }

  // ---- The Bin (by hand only) ----

  /// The Cloud page's Bin buttons (by the person's own press; no AI tool calls this): `bin` moves a session's chat to the
  /// Bin for 30 days, `restore` brings it back, `remove` removes a binned one now. Closing a session never calls it.
  public Task<bool> BinAsync(string? session, string? reference, string action) => Locked(async () =>
  {
    if (action is not ("bin" or "restore" or "remove") || session is null && reference is null) return false;
    var body = new Dictionary<string, string> { ["action"] = action };
    if (reference is not null) body["ref"] = reference; else body["session"] = session!;
    if (await CallAsync("POST", "/chats/bin", JsonSerializer.SerializeToUtf8Bytes(body)) is not Ok) return false;
    if (session is not null) { SessionOf(session).Binned = action is "bin" or "remove"; Save(); }
    return true;
  });

  // ---- Status ----

  /// What is held in the Cloud of the histories this PC lists, against their size here.
  public (int Listed, long Held, long Total) Progress()
  {
    var held = Saved.Sessions.Values.Sum(s => s.Streams.GetValueOrDefault("raw")?.Length ?? 0);
    var earlier = Saved.Archive.Values.Where(a => a.Found.Format != CloudChatsReadable.Format.AppChat).Sum(a => a.Bytes);
    return (Saved.Listed, held, Math.Max(SourceBytes + earlier, held));
  }
  /// `cloud.status`'s one line for agents: how many sessions are listed and how far the chat upload is. Read only;
  /// counts only, no chat text.
  public JsonObject StatusWire()
  {
    var (listed, held, total) = Progress();
    var percent = total == 0 ? 100 : (int)Math.Floor((double)held / total * 100);
    var line = Missing ? "Sessions in the Cloud are not live yet"
      : held >= total ? $"{listed} sessions listed; chats are up to date"
      : $"{listed} sessions listed; chats {percent}% uploaded ({Size(held)} of {Size(total)})";
    return new JsonObject
    {
      ["listed"] = listed, ["uploadedBytes"] = held, ["historyBytes"] = total, ["percent"] = percent, ["earlierChats"] = Saved.Archive.Count,
      ["earlierChatsDone"] = Saved.Archive.Values.Count(a => a.Stage == Stage.Done), ["live"] = !Missing, ["line"] = line
    };
  }
  private static string Size(long bytes) => bytes switch
  {
    >= 1_000_000_000 => (bytes / 1e9).ToString("0.#", CultureInfo.InvariantCulture) + " GB",
    >= 1_000_000 => (bytes / 1e6).ToString("0.#", CultureInfo.InvariantCulture) + " MB",
    >= 1_000 => (bytes / 1e3).ToString("0", CultureInfo.InvariantCulture) + " KB",
    _ => bytes.ToString(CultureInfo.InvariantCulture) + " bytes"
  };
}
