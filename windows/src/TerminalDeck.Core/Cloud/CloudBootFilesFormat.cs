using System.Globalization;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// 7C-3: AI instruction files ("boot files", inventory row I09) as they travel, byte for byte as the Mac makes them
// (td-mac-next TerminalDeckNativeCore CloudBootFiles.swift, CloudBootFilesRuns.swift, CloudBrainFiles.swift;
// TerminalDeckBackend BackendCloudBrainFiles.swift `operation`, BackendCloudBrainFilesImport.swift `check`,
// BackendCloudBootFilesApply.swift `describe`). One file version is cut into parts of 32 KiB; each part is one `put`
// record of the domain `brain/files/i09` whose payload is a `td-memory-part-1` object WITHOUT `stamp` or `baseline`
// (the Mac's file engine refuses both). A record's key is `file/<place>/<path inside the place>`, the place being
// `project/<token of the project id>` or `home/<claude|codex|gemini|agents>/<token>`: never a folder path.

/// Where boot files live: a project's folder, or the settings folder ("home") of one AI account.
public enum CloudBootFilesPlaceKind { Project, Claude, Codex, Gemini, Agents }

/// Why a path is not a boot file (CloudBootFilesRefusal). Each is a refusal for a record and an exclusion for a file.
public enum CloudBootFilesRefusal { Path, NotListed, Hidden, Never, Rebuildable }

/// Which of two versions of one file is used everywhere (the Mac's one rule).
public enum CloudBootFilesNewest { Local, Arrived }

/// One version's place in time for the one rule. `FirstCopy` (rule J): the first saved copy of a device that never held
/// this file's Cloud history; it loses to a version that is part of that history.
public sealed record CloudBootFilesVersionTime(long At, string Device, bool FirstCopy = false);

/// One incoming record, checked and described (BackendCloudBootFiles.describe + BackendCloudBrainFiles.check).
public sealed record CloudBootFilesIncoming(CloudOperation Operation, bool Archive, string SourceId, CloudBootFilesPlaceKind Kind, string Token,
  string Relative, string StoreId, string Key, string Version, string Hash, long Bytes, int Index, int Count, IReadOnlyList<string> Parents, byte[] Data);

public static class CloudBootFilesFormat
{
  public const string InventoryRow = "I09";
  public const string Domain = "brain/files/i09";
  public const int PartBytes = CloudMemoryFormat.PartBytes;
  public const int MaximumFileBytes = 1_048_576;
  public const int MaximumFilesPerPlace = 2_000;
  public const int MaximumFolderDepth = 12;
  public const int MaximumPathBytes = 512;
  /// A project has ONE folder per device in this version; every record of a project names it so.
  public const string ProjectRoot = "primary";
  public const string PartFormat = "td-memory-part-1";
  public const string ArchiveFormat = "td-file-archive-1";
  /// BackendCloudBrainFiles.partKeys / markerKeys: nothing else may be in a payload.
  public static readonly IReadOnlySet<string> PartKeys = new HashSet<string> { "format", "storeId", "inventoryRow", "key", "version", "resourceHash", "bytes", "index", "count", "parents", "data" };
  public static readonly IReadOnlySet<string> MarkerKeys = new HashSet<string> { "format", "storeId", "inventoryRow", "key", "version", "resourceHash", "parents" };

  public static string KindName(CloudBootFilesPlaceKind kind) => kind switch
  {
    CloudBootFilesPlaceKind.Project => "project", CloudBootFilesPlaceKind.Claude => "claude", CloudBootFilesPlaceKind.Codex => "codex",
    CloudBootFilesPlaceKind.Gemini => "gemini", _ => "agents"
  };
  private static CloudBootFilesPlaceKind? KindOf(string name) => name switch
  {
    "project" => CloudBootFilesPlaceKind.Project, "claude" => CloudBootFilesPlaceKind.Claude, "codex" => CloudBootFilesPlaceKind.Codex,
    "gemini" => CloudBootFilesPlaceKind.Gemini, "agents" => CloudBootFilesPlaceKind.Agents, _ => null
  };

  // ---- Place ids (BackendCloudBrainFilesNames.token, BackendCloudBootFiles.sourceId / parse) ----

  /// Lower-case hex of the UTF-8 bytes; a value longer than 40 bytes is "h" + the first 40 hex of its SHA-256.
  public static string Token(string value)
  {
    var hex = Convert.ToHexStringLower(Encoding.UTF8.GetBytes(value));
    return hex.Length <= 80 ? hex : "h" + CloudBytes.Sha256Hex(Encoding.UTF8.GetBytes(value))[..40];
  }
  /// The value of a hex token, or null (a hashed token cannot be read back).
  public static string? Untoken(string token)
  {
    if (token.StartsWith('h') || token.Length % 2 != 0) return null;
    try { return new UTF8Encoding(false, true).GetString(Convert.FromHexString(token)); }
    catch (Exception e) when (e is FormatException or DecoderFallbackException) { return null; }
  }
  public static string SourceId(CloudBootFilesPlaceKind kind, string identity) =>
    kind == CloudBootFilesPlaceKind.Project ? "project/" + Token(identity) : "home/" + KindName(kind) + "/" + Token(identity);
  public static (CloudBootFilesPlaceKind Kind, string Token)? ParseSourceId(string sourceId)
  {
    var fields = sourceId.Split('/');
    static bool IsToken(string text) => text.Length is > 0 and <= 80 && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f' or 'h');
    if (fields.Length == 2 && fields[0] == "project" && IsToken(fields[1])) return (CloudBootFilesPlaceKind.Project, fields[1]);
    if (fields.Length == 3 && fields[0] == "home" && KindOf(fields[1]) is { } kind && kind != CloudBootFilesPlaceKind.Project && IsToken(fields[2])) return (kind, fields[2]);
    return null;
  }
  /// BackendCloudBrainFilesSource.validSourceId.
  public static bool ValidSourceId(string id) => id.Length is > 0 and <= 96 && !id.StartsWith('-') && !id.EndsWith('/') && !id.Contains("//", StringComparison.Ordinal)
    && id.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '/');

  // ---- The list (CloudBootFilesRules) ----

  public static IReadOnlyList<string> Files(CloudBootFilesPlaceKind kind) => kind switch
  {
    CloudBootFilesPlaceKind.Project => ["CLAUDE.md", "AGENTS.md", "GEMINI.md"],
    CloudBootFilesPlaceKind.Claude => ["CLAUDE.md"],
    CloudBootFilesPlaceKind.Codex => ["AGENTS.md"],
    CloudBootFilesPlaceKind.Gemini => ["GEMINI.md"],
    _ => []
  };
  public static IReadOnlyList<string> Folders(CloudBootFilesPlaceKind kind) => kind switch
  {
    CloudBootFilesPlaceKind.Project => [".claude/agents", ".claude/skills", ".claude/commands", ".agents/skills", ".codex/skills", ".gemini/skills"],
    CloudBootFilesPlaceKind.Claude => ["agents", "skills", "commands"],
    _ => ["skills"]
  };
  /// Settings, hooks, MCP, permissions and sign-in files, by name (letter case ignored), also inside a listed folder.
  public static readonly IReadOnlySet<string> NeverFileNames = new HashSet<string>
  {
    "settings.json", "settings.local.json", "managed-settings.json", "hooks.json", "mcp.json", "mcp_config.json", "mcp-config.json",
    "config.toml", "permissions.json", "auth.json", "credentials.json", "oauth_creds.json", "google_accounts.json",
    "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"
  };
  public static readonly IReadOnlyList<string> NeverFileEndings = [".pem", ".key", ".p12", ".pfx", ".p8", ".jks", ".keystore", ".ppk", ".keychain", ".keychain-db", ".env",
    ".lock", ".pid", ".sock", ".socket"];
  public static readonly IReadOnlyList<string> NeverNameParts = ["credential", "secret", "token", "apikey", "api_key", "api-key", "service-account", "service_account",
    "password", "passwd", "private_key", "private-key", ".env."];
  public static readonly IReadOnlyList<string> NeverNamePrefixes = ["id_"];
  public static readonly IReadOnlySet<string> NeverFolderNames = new HashSet<string> { "hooks" };
  public static readonly IReadOnlySet<string> RebuildableFolderNames = new HashSet<string> { "node_modules", "__pycache__", "venv" };

  // ---- Paths ----

  /// The parts of a path split at every '/', or null when a mark joined to a slash would give the text two readings
  /// (the Mac compares whole characters; the disk compares bytes).
  public static string[]? Parts(string path)
  {
    var e = StringInfo.GetTextElementEnumerator(path);
    while (e.MoveNext()) if (e.GetTextElement() is { Length: > 1 } element && element.Contains('/')) return null;
    return path.Split('/');
  }
  private static bool Plain(Rune r)
  {
    var v = r.Value;
    if (v < 0x20 || v is >= 0x7f and <= 0x9f || v == '\\') return false;
    return !(v is >= 0x200b and <= 0x200f || v is >= 0x202a and <= 0x202e || v is >= 0x2060 and <= 0x2069 || v == 0xfeff);
  }
  /// One plain spelling of a path below a folder: no way up or out, no second spelling of the same name.
  public static bool CleanRelative(string relative)
  {
    if (relative.Length == 0 || Encoding.UTF8.GetByteCount(relative) > MaximumPathBytes) return false;
    try { _ = new UTF8Encoding(false, true).GetByteCount(relative); } catch (EncoderFallbackException) { return false; }
    if (!relative.EnumerateRunes().All(Plain)) return false;
    if (!string.Equals(relative, relative.Normalize(NormalizationForm.FormC), StringComparison.Ordinal) || Parts(relative) is not { } pieces) return false;
    return pieces.All(p => p.Length > 0 && p != "." && p != ".." && Encoding.UTF8.GetByteCount(p) <= 255);
  }
  private static bool NeverFile(string lower) =>
    NeverFileNames.Contains(lower) || NeverFileEndings.Any(e => lower.EndsWith(e, StringComparison.Ordinal))
    || NeverNameParts.Any(p => lower.Contains(p, StringComparison.Ordinal)) || NeverNamePrefixes.Any(p => lower.StartsWith(p, StringComparison.Ordinal));

  /// null when `relative` is a boot file of this kind of place. Letter case counts for the listed names; it is ignored
  /// for the names that never travel.
  public static CloudBootFilesRefusal? Refusal(CloudBootFilesPlaceKind kind, string relative)
  {
    if (!CleanRelative(relative) || Parts(relative) is not { } pieces) return CloudBootFilesRefusal.Path;
    if (pieces.Length == 1 && Files(kind).Contains(pieces[0], StringComparer.Ordinal)) return null;
    string[]? below = null;
    foreach (var folder in Folders(kind))
    {
      var lead = folder.Split('/');
      if (pieces.Length > lead.Length && lead.Select((x, i) => string.Equals(x, pieces[i], StringComparison.Ordinal)).All(b => b)) { below = pieces[lead.Length..]; break; }
    }
    if (below is null) return CloudBootFilesRefusal.NotListed;
    for (var i = 0; i < below.Length; i++)
    {
      var name = below[i];
      if (name.StartsWith('.')) return CloudBootFilesRefusal.Hidden;
      var lower = name.ToLowerInvariant();
      if (i < below.Length - 1)
      {
        if (NeverFolderNames.Contains(lower)) return CloudBootFilesRefusal.Never;
        if (RebuildableFolderNames.Contains(lower)) return CloudBootFilesRefusal.Rebuildable;
      }
      else if (NeverFile(lower)) return CloudBootFilesRefusal.Never;
    }
    return null;
  }

  /// Text: valid UTF-8 with no zero byte.
  public static bool IsText(ReadOnlySpan<byte> bytes)
  {
    if (bytes.Contains((byte)0)) return false;
    try { _ = new UTF8Encoding(false, true).GetCharCount(bytes); return true; }
    catch (DecoderFallbackException) { return false; }
  }

  // ---- The one rule (owner, 14 Nov): the newest change is used on every device ----

  /// A version's time when it is MADE: never later than now, never earlier than the version it was made on.
  public static long Clamp(long at, long? agreedAt, long now) => Math.Max(Math.Min(at, now), Math.Min(agreedAt ?? at, now));
  /// Rule J first (a first saved copy loses to a version with history), then the later time, then the larger device id.
  public static CloudBootFilesNewest Newest(CloudBootFilesVersionTime local, CloudBootFilesVersionTime arrived, long now)
  {
    if (local.FirstCopy != arrived.FirstCopy) return local.FirstCopy ? CloudBootFilesNewest.Arrived : CloudBootFilesNewest.Local;
    long mine = Math.Min(local.At, now), theirs = Math.Min(arrived.At, now);
    if (mine != theirs) return mine > theirs ? CloudBootFilesNewest.Local : CloudBootFilesNewest.Arrived;
    return string.CompareOrdinal(local.Device.ToLowerInvariant(), arrived.Device.ToLowerInvariant()) > 0 ? CloudBootFilesNewest.Local : CloudBootFilesNewest.Arrived;
  }

  // ---- What can run a command (CloudBootFilesRuns.swift) ----

  public static readonly IReadOnlySet<string> HarmlessHeaderKeys = new HashSet<string>
    { "name", "description", "argument-hint", "when_to_use", "color", "version", "license", "user-invocable", "disable-model-invocation" };
  public static readonly IReadOnlyList<string> InlineCommandMarks = ["!`", "```!", "!{"];
  public const string UnclearHeader = "header:unclear";

  private static List<string> Lines(string text)
  {
    var lines = new List<string>();
    var start = 0;
    for (var i = 0; i < text.Length; i++)
    {
      var c = text[i];
      if (c is not ('\n' or '\r' or '\u000b' or '\u000c' or '\u0085' or '\u2028' or '\u2029')) continue;
      lines.Add(text[start..i]);
      if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
      start = i + 1;
    }
    lines.Add(text[start..]);
    return lines;
  }
  private static string TrimSpaces(string s) => s.Trim(' ', '\t', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ',
    ' ', ' ', ' ', ' ', ' ', '　');

  private static List<string>? HeaderLines(string text)
  {
    var body = text.StartsWith('﻿') ? text[1..] : text;
    var lines = Lines(body);
    if (!lines[0].StartsWith("---", StringComparison.Ordinal)) return null;
    var block = new List<string>();
    if (TrimSpaces(lines[0]) != "---") block.Add(lines[0]);
    foreach (var line in lines.Skip(1))
    {
      if (line.StartsWith("---", StringComparison.Ordinal) && TrimSpaces(line) == "---") break;
      block.Add(line);
    }
    return block;
  }
  private static bool HeaderScalar(Rune r)
  {
    var v = r.Value;
    if (v < 0x20 || v is >= 0x7f and <= 0x9f || v == '\\') return false;
    return !(v is >= 0x200b and <= 0x200f || v is >= 0x2028 and <= 0x202e || v is >= 0x2060 and <= 0x2069 || v == 0xfeff);
  }
  private static (string Key, string Value)? KeyLine(string line)
  {
    var i = 0;
    char? quote = null;
    if (line.Length > 0 && line[0] is '"' or '\'') { quote = line[0]; i = 1; }
    var start = i;
    while (i < line.Length && (char.IsAsciiLetterOrDigit(line[i]) || line[i] is '-' or '_')) i++;
    var key = line[start..i];
    if (key.Length == 0 || !char.IsAsciiLetter(key[0])) return null;
    if (quote is { } q) { if (i >= line.Length || line[i] != q) return null; i++; }
    if (i >= line.Length || line[i] != ':') return null;
    i++;
    if (i < line.Length && line[i] != ' ') return null;
    return (key, line[i..]);
  }
  private static bool PlainValue(string value)
  {
    if (value.Length == 0) return true;
    var first = value[0];
    if (first is '"' or '\'')
    {
      var close = value.IndexOf(first, 1);
      if (close < 0) return false;
      var after = TrimSpaces(value[(close + 1)..]);
      return after.Length == 0 || after.StartsWith('#');
    }
    return !"&*!{}[]|>%@`?,-".Contains(first);
  }
  /// `header:<key>` for each key not on the harmless list, `header:unclear` once for anything not in the plain form.
  public static IReadOnlyList<string> HeaderReasons(string text)
  {
    if (HeaderLines(text) is not { } lines) return [];
    var reasons = new List<string>();
    var unclear = false;
    void Add(string reason) { if (!reasons.Contains(reason)) reasons.Add(reason); }
    var below = 0; // 0 nothing, 1 list, 2 block
    for (var index = 0; index < lines.Count; index++)
    {
      var line = lines[index];
      if (index == 0 && line.StartsWith("---", StringComparison.Ordinal)) { unclear = true; continue; }
      if (!line.EnumerateRunes().All(HeaderScalar)) { unclear = true; continue; }
      var trimmed = TrimSpaces(line);
      if (trimmed.Length == 0) continue;
      var indented = line[0] == ' ';
      if (indented && trimmed.StartsWith("---", StringComparison.Ordinal)) { unclear = true; continue; }
      if (below == 2 && indented) continue;
      if (trimmed == "..." || trimmed.StartsWith('%')) { unclear = true; continue; }
      if (!indented && trimmed.StartsWith('#')) { below = 0; continue; }
      if (below == 1 && (trimmed.StartsWith("- ", StringComparison.Ordinal) || trimmed == "-"))
      {
        if (trimmed != "-" && !PlainValue(trimmed[2..])) unclear = true;
        continue;
      }
      below = 0;
      if (indented || KeyLine(line) is not { } entry) { unclear = true; continue; }
      var key = entry.Key.ToLowerInvariant();
      if (!HarmlessHeaderKeys.Contains(key)) Add("header:" + key);
      var value = TrimSpaces(entry.Value);
      if (value.Length == 0 || value.StartsWith('#')) below = 1;
      else if (value is "|" or "|-" or "|+" or ">" or ">-" or ">+") below = 2;
      else if (!PlainValue(value)) unclear = true;
    }
    if (unclear) Add(UnclearHeader);
    return reasons;
  }
  private static bool ImportLeavesThePlace(string token)
  {
    var path = token.TrimStart('(', '[', '{', '<', '"', '\'', '`');
    if (path.Length == 0) return false;
    if (path[0] is '/' or '~' or '$' or '\\') return true;
    if (path.Contains("..", StringComparison.Ordinal) || path.Contains('\\') || path.Contains("://", StringComparison.Ordinal)) return true;
    return path.Length >= 2 && path[1] == ':' && char.IsAsciiLetter(path[0]);
  }
  /// `@` imports that reach outside the place, each once, as written (at most five).
  public static IReadOnlyList<string> OutsideImports(string text)
  {
    var found = new List<string>();
    var at = text.IndexOf('@');
    while (at >= 0)
    {
      var end = at + 1;
      while (end < text.Length && !char.IsWhiteSpace(text[end])) end++;
      var token = text[(at + 1)..end];
      if (ImportLeavesThePlace(token))
      {
        var shown = new StringBuilder();
        var count = 0;
        foreach (var r in token.EnumerateRunes())
        {
          if (count >= 80) { shown.Append('…'); break; }
          shown.Append(r.Value is >= 0x21 and <= 0x7e ? r.ToString() : "\\u{" + r.Value.ToString("x", CultureInfo.InvariantCulture) + "}");
          count++;
        }
        if (!found.Contains(shown.ToString())) found.Add(shown.ToString());
        if (found.Count == 5) break;
      }
      at = text.IndexOf('@', at + 1);
    }
    return found;
  }
  /// Why this file waits for the person; empty = plain text that applies by itself. The three instruction files at the
  /// top of a place wait only for an `@` import that reaches outside the place.
  public static IReadOnlyList<string> RunReasons(string relative, byte[] bytes)
  {
    if (Parts(relative) is not { Length: > 0 } pieces) return ["path"];
    if (!IsText(bytes)) return ["not-text"];
    var text = Encoding.UTF8.GetString(bytes);
    var imports = OutsideImports(text).Select(i => "import:" + i).ToList();
    if (pieces.Length == 1) return imports;
    var reasons = new List<string>();
    var lower = pieces[^1].ToLowerInvariant();
    if (!(lower.EndsWith(".md", StringComparison.Ordinal) || lower.EndsWith(".markdown", StringComparison.Ordinal) || lower.EndsWith(".txt", StringComparison.Ordinal)))
      reasons.Add("script-or-settings");
    if (text.StartsWith("#!", StringComparison.Ordinal)) reasons.Add("script");
    reasons.AddRange(HeaderReasons(text));
    if (InlineCommandMarks.Any(m => text.Contains(m, StringComparison.Ordinal))) reasons.Add("inline-command");
    reasons.AddRange(imports);
    return reasons;
  }

  // ---- Records (BackendCloudBrainFiles.operation) ----

  public static string EntityFor(string storeId, string key, int index) => CloudMemoryFormat.Uuid(storeId + "\n" + key + "\n" + index.ToString(CultureInfo.InvariantCulture));
  public static string OperationFor(string version, int index) => CloudMemoryFormat.OperationId(version + "\n" + index.ToString(CultureInfo.InvariantCulture));

  /// Every part of one file version, as the Mac's file engine makes them. Deterministic: the same version always gives
  /// the same records. Applies no rule to the key (the adapter does; tests use this to make forged records).
  public static IReadOnlyList<CloudOperation> Records(string storeId, string key, string sourceId, string version, IReadOnlyList<string> parents, byte[] data,
    string device, long createdAt, string? projectId, string? rootId)
  {
    var hash = CloudMemoryFormat.Hash(data);
    var count = CloudMemoryFormat.PartCount(data.Length);
    var operations = new List<CloudOperation>(count);
    for (var index = 0; index < count; index++)
    {
      var offset = index * PartBytes;
      var slice = data.AsSpan(offset, Math.Min(PartBytes, data.Length - offset));
      var payload = new CloudMemoryPart(storeId, InventoryRow, key, version, hash, data.Length, index, count, parents, Convert.ToBase64String(slice)).ToJson();
      var opId = OperationFor(version, index);
      operations.Add(new CloudOperation(1, opId, device, Domain, EntityFor(storeId, key, index), opId, parents.Select(p => OperationFor(p, index)).ToArray(), "put",
        projectId, rootId, new CloudSourceReference("files/" + InventoryRow + "/" + sourceId, key, offset, hash), createdAt, payload, CloudOperation.PayloadHashOf(payload)));
    }
    return operations;
  }

  private static bool LinksValid(CloudOperation op, string version, IReadOnlyList<string> parents, string suffix)
  {
    foreach (var make in new Func<string, string>[] { CloudMemoryFormat.OperationId, CloudMemoryFormat.Uuid })
      if (op.Revision == make(version + suffix)) return op.Parents.SequenceEqual(parents.Select(p => make(p + suffix)));
    return false;
  }
  private static bool IsHash(string text) => text.Length == 64 && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
  private static bool IsUuid(string text) => Guid.TryParseExact(text, "D", out _);

  /// Every check the Mac makes before it keeps a byte: the record's own identity, then the boot-file rules for its key.
  /// Throws `invalid_request` (the engine passes the record over for good) for anything that is not a boot file.
  public static CloudBootFilesIncoming Describe(CloudOperation op)
  {
    static CloudFailure Refused() => new("invalid_request");
    if (op.V != 1 || op.Domain != Domain || op.OpId != op.Revision || !IsUuid(op.OriginDevice) || !IsUuid(op.OpId)) throw Refused();
    if (CloudOperation.PayloadHashOf(op.Payload) != op.PayloadHash) throw Refused();
    if (op.Payload is not CloudJson.Object o) throw Refused();
    string Text(string k) => o[k]?.AsString ?? throw Refused();
    var archive = op.Kind switch { "put" => false, "archive" => true, _ => throw Refused() };
    if (o.Members.Any(m => !(archive ? MarkerKeys : PartKeys).Contains(m.Key)) || o.Members.Select(m => m.Key).Distinct().Count() != o.Members.Count) throw Refused();
    var parents = (o["parents"] as CloudJson.Array ?? throw Refused()).Items.Select(x => x.AsString ?? throw Refused()).ToArray();
    string storeId = Text("storeId"), key = Text("key"), version = Text("version"), hash = Text("resourceHash");
    if (Text("inventoryRow") != InventoryRow) throw Refused();
    long size = 0; int index = 0, count = 1; byte[] data = [];
    if (!archive)
    {
      if (Text("format") != PartFormat) throw Refused();
      var bytesText = Text("bytes");
      if (!long.TryParse(bytesText, NumberStyles.None, CultureInfo.InvariantCulture, out size) || size.ToString(CultureInfo.InvariantCulture) != bytesText) throw Refused();
      var indexValue = o["index"]?.AsInteger ?? throw Refused();
      var countValue = o["count"]?.AsInteger ?? throw Refused();
      if (indexValue is < 0 or > int.MaxValue || countValue is < 1 or > int.MaxValue) throw Refused();
      index = (int)indexValue; count = (int)countValue;
      try { data = Convert.FromBase64String(Text("data")); } catch (FormatException) { throw Refused(); }
      if (Convert.ToBase64String(data) != Text("data")) throw Refused();
      if (size > MaximumFileBytes || count != CloudMemoryFormat.PartCount(size) || index < 0 || index >= count
        || data.Length != (int)Math.Min(PartBytes, Math.Max(0, size - (long)index * PartBytes))) throw Refused();
      if (op.EntityId != EntityFor(storeId, key, index) || !LinksValid(op, version, parents, "\n" + index.ToString(CultureInfo.InvariantCulture))) throw Refused();
      if (data.AsSpan().Contains((byte)0)) throw Refused();
    }
    else
    {
      if (Text("format") != ArchiveFormat) throw Refused();
      if (op.EntityId != CloudMemoryFormat.Uuid(storeId + "\n" + key + "\narchive") || !LinksValid(op, version, parents, "\narchive")) throw Refused();
    }
    if (!IsUuid(storeId) || !IsUuid(version) || parents.Any(p => !IsUuid(p)) || parents.Distinct().Count() != parents.Length || !IsHash(hash) || op.Source.RecordId != key)
      throw Refused();
    // `file/project/<token>/<path>` or `file/home/<kind>/<token>/<path>`, split at slashes.
    if (Parts(key) is not { Length: >= 4 } fields || fields[0] != "file") throw Refused();
    var head = fields[1] == "project" ? 3 : 4;
    if (fields.Length <= head) throw Refused();
    var sourceId = string.Join('/', fields[1..head]);
    if (!ValidSourceId(sourceId) || ParseSourceId(sourceId) is not { } place) throw Refused();
    var relative = string.Join('/', fields[head..]);
    if (Refusal(place.Kind, relative) is not null) throw Refused();
    return new(op, archive, sourceId, place.Kind, place.Token, relative, storeId, key, version, hash, size, index, count, parents, data);
  }
}
