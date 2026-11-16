using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Cloud;

// Lane U1 (15 Nov), the Mac's BackendCloudShelfFiles.swift: open files with every computer off. A Cloud folder or
// artifact FILE on the shelf (a picture, a PDF, any binary, a text over 1 MB) carries `fileHash`, `fileBytes` and
// `fileType`; the service answers which files it still needs (`needFiles`) and this PC sends their bytes in 1 MiB pieces
// to `POST /v1/shelf/files`, one file at a time, oldest request first, inside half of the Cloud folder's daily send
// allowance. Safe with an older service: no `limits.fileKinds` = no file fields, nothing hashed, nothing sent; a missing
// route or any refusal = nothing more until the next daily put, never an error.
public static class CloudShelfFiles
{
  public const int FilePieceBytes = 1_048_576;
  public const long FileMaxBytes = 25_000_000;
  public const int FilesRoundBytes = 8 * 1_048_576;
  public static readonly long FilesDayShare = CloudFolderFormat.DailySendBytes / 2;
  public const long HashRoundBytes = 256_000_000;

  public sealed record NeedFile(string Hash, List<int> Pieces);
  /// What one file is, once read. `Hash` null = never sent (over 25 MB, or it holds a known secret).
  public sealed record FileFact(string? Hash, long Bytes, string Type);
  public sealed record FileAsk(string Item, CloudContentsKind Kind, string Root, string Relative, bool IsText);
  public sealed class FilesFound
  {
    public Dictionary<string, (string Key, FileFact Fact)> ByItem { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, FileFact> Keep { get; } = new(StringComparer.Ordinal);
    public bool Pending { get; set; }
    public int Read { get; set; }
  }

  public static int FilePieces(long bytes) => (int)Math.Max(1, (bytes + FilePieceBytes - 1) / FilePieceBytes);
  /// Piece `index` of `data`: bytes [index * 1 MiB, min((index + 1) * 1 MiB, size)); null when out of range.
  public static byte[]? FilePiece(byte[] data, int index)
  {
    if (index < 0 || index >= FilePieces(data.LongLength)) return null;
    var start = index * FilePieceBytes;
    return data[start..Math.Min(start + FilePieceBytes, data.Length)];
  }
  private static string FileKey(CloudContentsKind kind, string relative, CloudFolderDisk.Stamp stamp) =>
    CloudShelf.Raw(kind) + "|" + relative + "|" + stamp.Bytes + "|" + stamp.Modified;
  /// The same secret check the shelf's texts use.
  public static bool HoldsSecret(string relative, byte[] data) =>
    CloudArtifactsFormat.HoldsSecret(relative, data) || CloudArtifactSecrets.ContainsKnownSecret(Encoding.UTF8.GetString(data));

  /// The facts of the listed files, read with the Cloud folder's own reader (never through a link). A file whose size and
  /// change time are known is never read again. Text items up to 1 MB are not files. At most `budget` bytes are read.
  public static FilesFound FileFacts(IReadOnlyList<FileAsk> asks, IReadOnlyDictionary<string, FileFact> known, long budget = HashRoundBytes)
  {
    var found = new FilesFound();
    long spent = 0;
    foreach (var ask in asks)
    {
      if (ask.Relative.Length == 0 || CloudFolderDisk.StampOf(ask.Root, ask.Relative) is not { } stamp) continue;
      if (ask.IsText && stamp.Bytes <= CloudShelf.TextMaxBytes) continue;
      var key = FileKey(ask.Kind, ask.Relative, stamp);
      var type = CloudShelf.FileType(ask.Relative);
      var fact = known.GetValueOrDefault(key);
      if (fact is null && stamp.Bytes > FileMaxBytes) fact = new FileFact(null, stamp.Bytes, type);
      if (fact is null)
      {
        if (spent != 0 && spent + stamp.Bytes > budget) { found.Pending = true; continue; }
        if (CloudFolderDisk.Read(ask.Root, ask.Relative) is not { IsFile: true } read || read.Bytes!.LongLength != stamp.Bytes
          || CloudFolderDisk.StampOf(ask.Root, ask.Relative) != stamp) continue;
        spent += stamp.Bytes;
        found.Read++;
        fact = new FileFact(HoldsSecret(ask.Relative, read.Bytes) ? null : CloudShelf.Hash(read.Bytes), stamp.Bytes, type);
      }
      found.Keep[key] = fact;
      found.ByItem[ask.Item] = (key, fact);
    }
    return found;
  }

  /// The bytes of a file the service asked for, read again: only when they are still exactly `hash`. null = do not send.
  public static byte[]? FileBytes(string root, string relative, string expected)
  {
    if (CloudFolderDisk.StampOf(root, relative) is not { } stamp || stamp.Bytes > FileMaxBytes) return null;
    if (CloudFolderDisk.Read(root, relative) is not { IsFile: true } read || read.Bytes!.LongLength != stamp.Bytes) return null;
    return CloudShelf.Hash(read.Bytes) == expected && !HoldsSecret(relative, read.Bytes) ? read.Bytes : null;
  }

  /// A row with its file's three fields (only a file with a hash).
  public static CloudShelf.Row WithFile(CloudShelf.Row row, FileFact? fact) =>
    fact is { Hash: { } hash } && fact.Bytes <= FileMaxBytes ? row with { FileHash = hash, FileBytes = fact.Bytes, FileType = fact.Type } : row;

  /// A list put's answer: what the service still needs of this kind's files. Files already done keep counting.
  public static void Ask(CloudShelfPutter.KindState known, CloudContentsKind kind, IReadOnlyList<NeedFile>? needFiles, long now)
  {
    if (!CloudShelf.FileKinds.Contains(kind)) return;
    var seen = new HashSet<string>(StringComparer.Ordinal);
    var need = new List<NeedFile>();
    foreach (var file in needFiles ?? [])
    {
      if (file?.Hash is null || !Regex.IsMatch(file.Hash, "^[0-9a-f]{64}$") || !seen.Add(file.Hash)) continue;
      var pieces = (file.Pieces ?? []).Where(p => p >= 0 && p < FilePieces(FileMaxBytes)).Distinct().Order().ToList();
      if (pieces.Count > 0) need.Add(new NeedFile(file.Hash, pieces));
    }
    if (need.Count == 0) { known.FilesOwed = null; known.FilesAsked = null; known.FilesDone = null; known.FilesAskedAt = null; return; }
    var unfinished = (known.FilesOwed?.Count ?? 0) > 0;
    var done = unfinished ? known.FilesDone ?? 0 : 0;
    known.FilesOwed = need;
    known.FilesDone = done;
    known.FilesAsked = done + need.Count;
    if (!unfinished || known.FilesAskedAt is null) known.FilesAskedAt = now;
  }
}

public sealed partial class CloudShelfPutter
{
  private readonly HashSet<CloudContentsKind> filesFresh = [];
  private readonly Dictionary<CloudContentsKind, long> filesRetryAt = [];

  /// The service keeps files of this kind (its `limits.fileKinds`) and the setting is on.
  public bool FilesLive(CloudContentsKind kind) =>
    Current.On && !Missing && CloudShelf.FileKinds.Contains(kind) && (Current.FileKinds ?? []).Contains(CloudShelf.Raw(kind));
  public IReadOnlyDictionary<string, CloudShelfFiles.FileFact> KnownFiles() => Current.Files ?? new Dictionary<string, CloudShelfFiles.FileFact>();
  public void RememberFiles(Dictionary<string, CloudShelfFiles.FileFact> facts)
  {
    var held = Current.Files ?? [];
    if (facts.Count == held.Count && facts.All(f => held.TryGetValue(f.Key, out var v) && v == f.Value)) return;
    Current.Files = facts.Count == 0 ? null : facts;
    Save();
  }
  /// "12 of 80" while files are still going up; null when nothing is owed.
  public (int Done, int Total)? FilesProgress()
  {
    int done = 0, total = 0;
    foreach (var kind in CloudShelf.FileKinds.Where(FilesLive))
    {
      if (Current.Kinds.GetValueOrDefault(CloudShelf.Raw(kind)) is not { } known || (known.FilesOwed?.Count ?? 0) == 0) continue;
      done += known.FilesDone ?? 0;
      total += known.FilesAsked ?? 0;
    }
    return total > done ? (done, total) : null;
  }

  private KindState Of(CloudContentsKind kind)
  {
    var raw = CloudShelf.Raw(kind);
    if (!Current.Kinds.TryGetValue(raw, out var known)) Current.Kinds[raw] = known = new KindState();
    return known;
  }
  private static void Clear(KindState k) { k.FilesOwed = null; k.FilesAsked = null; k.FilesDone = null; k.FilesAskedAt = null; }
  private void HoldFiles(IEnumerable<CloudContentsKind> kinds, long now)
  {
    foreach (var kind in kinds) { var k = Of(kind); Clear(k); k.FilesHoldUntil = now + CloudShelf.DayMs; }
    Save();
  }
  private void FinishFile(CloudContentsKind kind, string hash, bool sent)
  {
    var k = Of(kind);
    k.FilesOwed?.RemoveAll(f => f.Hash == hash);
    if (sent) k.FilesDone = (k.FilesDone ?? 0) + 1;
    else k.FilesAsked = Math.Max(k.FilesDone ?? 0, (k.FilesAsked ?? 1) - 1);
    if (k.FilesOwed is { Count: 0 }) Clear(k);
    Save();
  }

  /// Sends what the service asked for: one file at a time (oldest request first), piece by piece. `maySend` is the day's
  /// allowance, `spent` books what went, `bytes` reads a file for its hash again. Returns the pieces sent.
  public async Task<int> SendFilesAsync(long now, Func<long, bool> maySend, Action<long> spent, Func<CloudContentsKind, string, Task<byte[]?>> bytes)
  {
    int sentBytes = 0, sentPieces = 0;
    try
    {
      while (sentBytes < CloudShelfFiles.FilesRoundBytes && Current.On && !Missing)
      {
        var waiting = CloudShelf.FileKinds.Where(kind => FilesLive(kind) && Current.Kinds.GetValueOrDefault(CloudShelf.Raw(kind)) is { } k && (k.FilesOwed?.Count ?? 0) > 0
          && (k.FilesHoldUntil ?? 0) <= now && filesRetryAt.GetValueOrDefault(kind) <= now).ToList();
        if (waiting.Count == 0) break;
        var kind = waiting.OrderBy(k => Current.Kinds[CloudShelf.Raw(k)].FilesAskedAt ?? 0).ThenBy(k => CloudShelf.Raw(k), StringComparer.Ordinal).First();
        if (filesFresh.Add(kind))
        {
          if (await StatusAsync(kind) is not { } status) return sentPieces;
          if (status.NeedFiles is not { } need) { HoldFiles([kind], now); continue; }
          CloudShelfFiles.Ask(Of(kind), kind, need, now);
          continue;
        }
        if (Of(kind).FilesOwed?.FirstOrDefault() is not { } file) break;
        byte[]? data;
        try { data = await bytes(kind, file.Hash); } catch { data = null; }
        if (data is null || data.LongLength > CloudShelfFiles.FileMaxBytes) { FinishFile(kind, file.Hash, false); continue; }
        var whole = true;
        foreach (var piece in file.Pieces.ToArray())
        {
          if (CloudShelfFiles.FilePiece(data, piece) is not { } chunk) { whole = false; break; }
          if (sentBytes > 0 && sentBytes + chunk.Length > CloudShelfFiles.FilesRoundBytes) return sentPieces;
          if (!maySend(chunk.Length)) return sentPieces;
          var body = CloudShelfJson.Encode(new CloudShelfJson.Obj().Add("kind", CloudShelf.Raw(kind)).Add("hash", file.Hash).Add("piece", piece)
            .Add("data", Convert.ToBase64String(chunk)));
          var answer = await CallAsync("POST", "/shelf/files", body, quiet404: true);
          if (answer.Kind == Kind.Lost) return sentPieces;
          if (answer.Kind == Kind.Refused)
          {
            if (answer.Status == 429) { filesRetryAt[kind] = now + Math.Max(answer.RetryAfterMs ?? 0, CloudShelf.SettleMs); return sentPieces; }
            if (answer.Status == 404 || answer.Code == "not_found") { Current.FileKinds = []; Current.FileKindsAt = now; }
            HoldFiles(CloudShelf.FileKinds, now);
            return sentPieces;
          }
          bool stored = false;
          string? code = null;
          try
          {
            using var doc = JsonDocument.Parse(answer.Data);
            stored = doc.RootElement.TryGetProperty("stored", out var s) && s.ValueKind == JsonValueKind.True;
            if (doc.RootElement.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String) code = c.GetString();
          }
          catch (JsonException) { }
          if (!stored)
          {
            if (code == "file_mismatch" && Current.Files is { } facts) Current.Files = facts.Where(f => f.Value.Hash != file.Hash).ToDictionary(f => f.Key, f => f.Value);
            whole = false;
            break;
          }
          spent(chunk.Length);
          sentBytes += chunk.Length;
          sentPieces++;
          file.Pieces.Remove(piece);
        }
        FinishFile(kind, file.Hash, whole);
      }
      return sentPieces;
    }
    finally { if (sentPieces > 0) Save(); }
  }
}
