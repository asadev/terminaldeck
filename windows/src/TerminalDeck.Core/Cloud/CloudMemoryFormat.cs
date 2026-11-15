using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// W3: Deck Memory as it travels, byte for byte as the Mac makes it (TerminalDeckNativeCore CloudBrainMemory.swift;
// TerminalDeckBackend DeckMemoryStoreCloudSchema.swift, BackendCloudBrainMemory.swift, BackendCloudBrainMemoryHash.swift,
// DeckMemoryStoreCloudExport.swift, DeckMemoryStoreCloudImport.swift cloudValidatePart). A memory resource (one table
// row, or one memory-folder file) is cut into parts of 32 KiB; each part is one `put` record of the domain
// `brain/memory/i0N` whose payload is a `td-memory-part-1` object.

/// One cell as it travels: type `null`, `text`, `integer` (decimal text), `real` (Swift's shortest form) or `blob`
/// (standard base64). The value member is absent for null.
public sealed record DeckMemoryCell(string Type, string? Value)
{
  public static DeckMemoryCell Null { get; } = new("null", null);
  public static DeckMemoryCell Text(string value) => new("text", value);
  public static DeckMemoryCell Integer(long value) => new("integer", value.ToString(CultureInfo.InvariantCulture));
  public static DeckMemoryCell Real(double value) => new("real", CloudMemoryFormat.SwiftDouble(value));
  public static DeckMemoryCell Blob(byte[] value) => new("blob", Convert.ToBase64String(value));
  public bool IsNull => Type == "null";
  public long? AsInteger => Type == "integer" && long.TryParse(Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : null;
  public CloudJson ToJson() => CloudJson.Obj(("type", CloudJson.From(Type)), ("value", Value is null ? null : CloudJson.From(Value)));
  public static DeckMemoryCell FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o || o.Members.Any(m => m.Key is not ("type" or "value"))) throw new CloudFailure("invalid_request");
    var type = o["type"]?.AsString ?? throw new CloudFailure("invalid_request");
    var text = o["value"] switch { null or CloudJson.Null => null, CloudJson.String s => s.Value, _ => throw new CloudFailure("invalid_request") };
    var cell = new DeckMemoryCell(type, text);
    switch (type)
    {
      case "null" when text is null: break;
      case "text" when text is not null: break;
      case "integer" when text is not null && long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) && n.ToString(CultureInfo.InvariantCulture) == text: break;
      case "real" when text is not null && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && double.IsFinite(d): break;
      case "blob" when text is not null && IsBase64(text): break;
      default: throw new CloudFailure("invalid_request");
    }
    return cell;
  }
  private static bool IsBase64(string text) { try { return Convert.ToBase64String(Convert.FromBase64String(text)) == text; } catch (FormatException) { return false; } }
}

/// A reference column's target, kept as the target's ORIGINAL identity (store and id), never this PC's local id.
public sealed record DeckMemoryReference(string StoreId, string Table, DeckMemoryCell Id)
{
  public CloudJson ToJson() => CloudJson.Obj(("id", Id.ToJson()), ("storeId", CloudJson.From(StoreId)), ("table", CloudJson.From(Table)));
}

/// One memory table (DeckMemoryCloudSchema.tables): its inventory row, its columns in order and its key columns.
public sealed record DeckMemoryTable(string Name, string Row, IReadOnlyList<string> Columns, IReadOnlyList<string> Keys, bool IntegerKey)
{
  public int Index(string column) => Columns.ToList().IndexOf(column);
}

public static class DeckMemoryCloudSchema
{
  private static DeckMemoryTable T(string name, string row, string columns, string[]? keys = null, bool integerKey = false) => new(name, row, columns.Split(','), keys ?? ["id"], integerKey);
  public static readonly IReadOnlyList<DeckMemoryTable> Tables =
  [
    T("diary", "I02", "id,owner,project,session,agent,role,text,conversation,turn,external_id,at,saved,meta,hand,job,author,rewound,rewind_id", integerKey: true),
    T("board", "I03", "id,kind,title,owner,project,session,agent,doing,last_result,waiting,state,proof,updated,archived,hand,job"),
    T("board_history", "I03", "id,row_id,at,fields,snapshot", integerKey: true),
    T("handoffs", "I04", "id,path,owner,topic,title,project,session,agent,hand,job,author,date,updated,archived,archive_reason,origin_path"),
    T("rewinds", "I04", "id,owner,conversation,after_row,at,rows,notes,topics,undo,undone", integerKey: true),
    T("settings", "I05", "owner,key,value,updated", ["owner", "key"]),
    T("questions", "I05", "id,owner,text,context,refs,asked,answer,answered,dismissed", integerKey: true),
    T("notes", "I05", "id,path,title,type,owner,project,session,agent,date,source,supersedes,superseded_by,archived,archive_reason,origin_path,updated,hand,job,valid_from,valid_until,diary_first,diary_last,author"),
    T("topics", "I05", "owner,id,title,path,open,project,session,agent,date,hand,job", ["owner", "id"]),
    T("files", "I05", "path,kind,owner", ["path"]),
    T("meta", "I05", "key,value", ["key"])
  ];
  /// M3: ONLY these shared memory settings travel; every other setting and the whole `meta` table stay on this PC.
  public static readonly IReadOnlyList<string> SharedSettingKeys = ["card.limit", "seat.title", "seat.parent", "seat.folded-into",
    "helper.ai", "helper.model", "helper.on", "helper.parallel", "helper.pause-seconds", "tidy.hour", "tidy.on",
    // The Mac's one rule: "Clean up now" and "Empty Bin" times. Windows keeps them as values and acts on neither.
    "cleanup.versions-before", "cleanup.bin-before"];
  /// One shared key per device: "this device understands removal records". Windows never writes one of its own.
  public const string SharedSettingPrefix = "onerule.understands.";
  /// Natural-key rows where the newest value wins (the loser is kept and listed); every other table keeps both.
  public static readonly IReadOnlySet<string> LastWriterTables = new HashSet<string> { "settings", "meta", "topics", "files", "notes", "handoffs" };
  public static readonly IReadOnlySet<string> AppHelpFiles = new HashSet<string> { "START-HERE.md", "CLAUDE.md", "AGENTS.md", "GEMINI.md" };

  public static DeckMemoryTable Table(string name) => Tables.FirstOrDefault(t => t.Name == name) ?? throw new CloudFailure("unsupported_format");
  public static bool IsMachineLocalSetting(string key) => !SharedSettingKeys.Contains(key) && !key.StartsWith(SharedSettingPrefix, StringComparison.Ordinal);
  public static bool IsMachineLocal(DeckMemoryTable t, IReadOnlyList<DeckMemoryCell> cells) =>
    t.Name == "meta" || t.Name == "settings" && cells[t.Index("key")] is { Type: "text", Value: var key } && IsMachineLocalSetting(key!);
  /// A removed shared setting travels as the same row with `value` null; `updated` carries the removal time.
  public static bool IsSettingTombstone(DeckMemoryTable t, IReadOnlyList<DeckMemoryCell> cells) => t.Name == "settings" && cells[t.Index("value")].IsNull;
  public static IReadOnlyDictionary<string, string> ReferenceColumns(string table) => table switch
  {
    "diary" => new Dictionary<string, string> { ["rewind_id"] = "rewinds" },
    "rewinds" => new Dictionary<string, string> { ["after_row"] = "diary" },
    "notes" => new Dictionary<string, string> { ["diary_first"] = "diary", ["diary_last"] = "diary", ["supersedes"] = "notes", ["superseded_by"] = "notes" },
    "board_history" => new Dictionary<string, string> { ["row_id"] = "board" },
    _ => new Dictionary<string, string>()
  };
  /// Which inventory row a memory-folder file belongs to; null for what never travels (the database, its backups,
  /// Cloud's own and hidden files).
  public static string? FileRow(string path)
  {
    var parts = path.Split('/');
    if (path.StartsWith("memory.db", StringComparison.Ordinal) || parts.Any(p => p.StartsWith(".cloud", StringComparison.Ordinal) || p == ".DS_Store" || p.StartsWith('.'))) return null;
    if ((path.StartsWith("archive/backups/", StringComparison.Ordinal) || path.Contains("/archive/backups/", StringComparison.Ordinal))
      && new[] { ".db", ".db-wal", ".db-shm", ".db-journal", "-wal", "-shm", "-journal" }.Any(s => path.EndsWith(s, StringComparison.Ordinal))) return null;
    if (path.StartsWith("archive/", StringComparison.Ordinal)) return "I06";
    if (path.Contains("/handoffs/", StringComparison.Ordinal) && path.EndsWith(".md", StringComparison.Ordinal)) return "I04";
    return "I01";
  }
  public static bool SafePath(string path) => path.Length > 0 && !path.StartsWith('/') && !path.Contains('\\') && !path.Contains('\0')
    && path.Split('/').All(p => p.Length > 0 && p != "." && p != ".." && !p.StartsWith(".cloud", StringComparison.Ordinal));
}

/// One part's payload (CloudBrainMemoryPart). `Data` is standard base64 of this part's bytes.
public sealed record CloudMemoryPart(string StoreId, string InventoryRow, string Key, string Version, string ResourceHash, long Bytes, int Index, int Count,
  IReadOnlyList<string> Parents, string Data, long? Stamp = null, bool? Baseline = null)
{
  public const string Format = "td-memory-part-1";
  public CloudJson ToJson() => CloudJson.Obj(("format", CloudJson.From(Format)), ("storeId", CloudJson.From(StoreId)), ("inventoryRow", CloudJson.From(InventoryRow)),
    ("key", CloudJson.From(Key)), ("version", CloudJson.From(Version)), ("resourceHash", CloudJson.From(ResourceHash)),
    ("bytes", CloudJson.From(Bytes.ToString(CultureInfo.InvariantCulture))), ("index", CloudJson.From(Index)), ("count", CloudJson.From(Count)),
    ("parents", CloudJson.Arr(Parents.Select(p => CloudJson.From(p)))), ("data", CloudJson.From(Data)),
    ("stamp", Stamp is { } s ? CloudJson.From(s.ToString(CultureInfo.InvariantCulture)) : null), ("baseline", Baseline is { } b ? CloudJson.From(b) : null));
}

public static class CloudMemoryFormat
{
  public const int PartBytes = 32 * 1024;
  public static readonly IReadOnlyList<string> InventoryRows = ["I01", "I02", "I03", "I04", "I05", "I06"];
  public static string Domain(string row) => InventoryRows.Contains(row) ? "brain/memory/" + row.ToLowerInvariant() : throw new CloudFailure("invalid_request");
  public static string? RowOfDomain(string domain) => InventoryRows.FirstOrDefault(r => Domain(r) == domain);

  /// DeckMemoryRemoval.parse (the Mac's one rule): a removal travels as a version of the file whose text is a small
  /// front-matter block with `td_removed: <ms>`. Windows never places one over a file and never sends one.
  public const int RemovalMarkerLimit = 16_384;
  public static bool IsRemovalMarker(byte[] bytes)
  {
    if (bytes.Length >= RemovalMarkerLimit || bytes.Length < 3 || bytes[0] != (byte)'-' || bytes[1] != (byte)'-' || bytes[2] != (byte)'-') return false;
    string text;
    try { text = new UTF8Encoding(false, true).GetString(bytes); } catch (DecoderFallbackException) { return false; }
    var lines = text.Split('\n');
    if (lines[0].Trim() != "---") return false;
    for (var i = 1; i < lines.Length; i++)
    {
      var line = lines[i];
      if (line.Trim() == "---") return false;
      var colon = line.IndexOf(':');
      if (colon <= 0 || line[0] is ' ' or '\t' || line[..colon].Trim() != "td_removed") continue;
      var value = line[(colon + 1)..].Trim();
      if (value.Length >= 2 && (value[0] == '"' && value[^1] == '"' || value[0] == '\'' && value[^1] == '\'')) value = value[1..^1];
      // The Mac reads only the first `td_removed` line, and only inside a closed front-matter block.
      if (!long.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _)) return false;
      for (var j = i + 1; j < lines.Length; j++) if (lines[j].Trim() == "---") return true;
      return false;
    }
    return false;
  }

  /// BackendCloudBrainMemoryHash.uuid: the first 16 bytes of SHA-256(text) in the version-5 layout (entities, versions).
  public static string Uuid(string text) => Shaped(text, 0x50);
  /// BackendCloudBrainMemoryHash.operationId: the same hash in the version-4 layout (op ids and their parents).
  public static string OperationId(string text) => Shaped(text, 0x40);
  private static string Shaped(string text, byte version)
  {
    var b = SHA256.HashData(Encoding.UTF8.GetBytes(text)).AsSpan(0, 16).ToArray();
    b[6] = (byte)((b[6] & 15) | version); b[8] = (byte)((b[8] & 63) | 128);
    var h = Convert.ToHexStringLower(b);
    return $"{h[..8]}-{h[8..12]}-{h[12..16]}-{h[16..20]}-{h[20..]}";
  }
  public static string Hash(ReadOnlySpan<byte> bytes) => CloudBytes.Sha256Hex(bytes);
  public static string OpIdFor(string version, int index, string device) => OperationId(version + "\n" + index.ToString(CultureInfo.InvariantCulture) + "\n" + device);
  public static string EntityFor(string storeId, string key, int index) => Uuid(storeId + "\n" + key + "\n" + index.ToString(CultureInfo.InvariantCulture));
  public static int PartCount(long bytes) => (int)Math.Max(1, (bytes + PartBytes - 1) / PartBytes);

  /// The canonical row body (CloudBrainMemoryRow): table, columns, cells and references (always present, maybe empty).
  public static byte[] RowBody(DeckMemoryTable t, IReadOnlyList<DeckMemoryCell> cells, IReadOnlyDictionary<string, DeckMemoryReference>? references = null) =>
    CloudCanonical.Encode(CloudJson.Obj(("table", CloudJson.From(t.Name)), ("columns", CloudJson.Arr(t.Columns.Select(c => CloudJson.From(c)))),
      ("cells", CloudJson.Arr(cells.Select(c => c.ToJson()))),
      ("references", CloudJson.Obj((references ?? new Dictionary<string, DeckMemoryReference>()).Select(r => (r.Key, (CloudJson?)r.Value.ToJson())).ToArray()))));
  public static (DeckMemoryTable Table, IReadOnlyList<DeckMemoryCell> Cells, IReadOnlyDictionary<string, DeckMemoryReference> References) DecodeRow(byte[] body)
  {
    if (CloudJson.Parse(body) is not CloudJson.Object o || o.Members.Any(m => m.Key is not ("table" or "columns" or "cells" or "references"))) throw new CloudFailure("unsupported_format");
    var t = DeckMemoryCloudSchema.Table(o["table"]?.AsString ?? throw new CloudFailure("unsupported_format"));
    var columns = (o["columns"] as CloudJson.Array ?? throw new CloudFailure("unsupported_format")).Items.Select(c => c.AsString).ToArray();
    var cells = (o["cells"] as CloudJson.Array ?? throw new CloudFailure("unsupported_format")).Items.Select(DeckMemoryCell.FromJson).ToArray();
    if (!columns.SequenceEqual(t.Columns) || cells.Length != t.Columns.Count) throw new CloudFailure("unsupported_format");
    var references = new Dictionary<string, DeckMemoryReference>(StringComparer.Ordinal);
    if (o["references"] is CloudJson.Object refs)
      foreach (var (column, value) in refs.Members)
      {
        var r = value as CloudJson.Object ?? throw new CloudFailure("invalid_request");
        references[column] = new(r["storeId"]?.AsString ?? throw new CloudFailure("invalid_request"), r["table"]?.AsString ?? throw new CloudFailure("invalid_request"),
          DeckMemoryCell.FromJson(r["id"] ?? throw new CloudFailure("invalid_request")));
      }
    return (t, cells, references);
  }
  /// The canonical key cells (DeckMemoryCloudSchema.nativeKey) and the resource key `row/<table>/<sha256 of them>`.
  public static string NativeKey(DeckMemoryTable t, IReadOnlyList<DeckMemoryCell> cells) =>
    Encoding.UTF8.GetString(CloudCanonical.Encode(CloudJson.Arr(t.Keys.Select(k => cells[t.Index(k)].ToJson()))));
  public static string RowKey(DeckMemoryTable t, IReadOnlyList<DeckMemoryCell> cells) => "row/" + t.Name + "/" + Hash(Encoding.UTF8.GetBytes(NativeKey(t, cells)));

  /// One part as a record (BackendCloudBrainMemoryParts.next + DeckMemoryStore.cloudCanonicalExportOperation).
  public static CloudOperation Operation(CloudMemoryPart part, string device, IReadOnlyList<string> parentOps, long createdAt)
  {
    var payload = part.ToJson();
    var opId = OpIdFor(part.Version, part.Index, device);
    return new CloudOperation(1, opId, device, Domain(part.InventoryRow), EntityFor(part.StoreId, part.Key, part.Index), opId, parentOps, "put", null, null,
      new CloudSourceReference("memory/" + part.InventoryRow, part.Key, (long)part.Index * PartBytes, part.ResourceHash), createdAt, payload, CloudOperation.PayloadHashOf(payload));
  }

  /// cloudValidatePart: everything a part states must agree with how it was made.
  public static CloudMemoryPart ValidatePart(CloudOperation op, string row)
  {
    if (op.V != 1 || op.Domain != Domain(row) || op.Kind != "put" || !Guid.TryParse(op.OpId, out _) || !Guid.TryParse(op.OriginDevice, out _)
      || CloudOperation.PayloadHashOf(op.Payload) != op.PayloadHash) throw new CloudFailure("checksum_mismatch");
    if (op.Payload is not CloudJson.Object o || o.Members.Any(m => m.Key is not ("format" or "storeId" or "inventoryRow" or "key" or "version" or "resourceHash" or "bytes" or "index" or "count" or "parents" or "data" or "stamp" or "baseline")))
      throw new CloudFailure("invalid_request");
    string Text(string k) => o[k]?.AsString ?? throw new CloudFailure("invalid_request");
    long Int(string k) => o[k]?.AsInteger ?? throw new CloudFailure("invalid_request");
    var bytesText = Text("bytes");
    if (!long.TryParse(bytesText, NumberStyles.None, CultureInfo.InvariantCulture, out var size) || size.ToString(CultureInfo.InvariantCulture) != bytesText) throw new CloudFailure("invalid_request");
    long? stamp = null;
    if (o["stamp"] is { } st && st is not CloudJson.Null)
    {
      var s = st.AsString ?? throw new CloudFailure("invalid_request");
      if (!long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var sv) || sv.ToString(CultureInfo.InvariantCulture) != s) throw new CloudFailure("invalid_request");
      stamp = sv;
    }
    var p = new CloudMemoryPart(Text("storeId"), Text("inventoryRow"), Text("key"), Text("version"), Text("resourceHash"), size, (int)Int("index"), (int)Int("count"),
      (o["parents"] as CloudJson.Array ?? throw new CloudFailure("invalid_request")).Items.Select(x => x.AsString ?? throw new CloudFailure("invalid_request")).ToArray(),
      Text("data"), stamp, o["baseline"] switch { null or CloudJson.Null => null, CloudJson.Bool b => b.Value, _ => throw new CloudFailure("invalid_request") });
    byte[] data;
    try { data = Convert.FromBase64String(p.Data); } catch (FormatException) { throw new CloudFailure("invalid_request"); }
    if (Text("format") != CloudMemoryPart.Format || p.InventoryRow != row || !Guid.TryParse(p.StoreId, out _) || !Guid.TryParse(p.Version, out _)
      || p.Count != PartCount(size) || p.Index < 0 || p.Index >= p.Count || p.ResourceHash.Length != 64 || !p.ResourceHash.All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f')
      || p.Parents.Count > 2 || p.Parents.Any(x => !Guid.TryParse(x, out _) || x == p.Version) || Convert.ToBase64String(data) != p.Data
      || data.Length != (int)Math.Min(PartBytes, size - (long)p.Index * PartBytes) || op.OpId != op.Revision
      || op.Source.SourceId != "memory/" + row || op.Source.RecordId != p.Key || op.Source.Offset != (long)p.Index * PartBytes || op.Source.RawHash != p.ResourceHash
      || op.EntityId != EntityFor(p.StoreId, p.Key, p.Index)) throw new CloudFailure("invalid_request");
    if (p.Key.StartsWith("file/", StringComparison.Ordinal))
    {
      var path = p.Key[5..];
      if (!DeckMemoryCloudSchema.SafePath(path)) throw new CloudFailure("invalid_request");
      if (!DeckMemoryCloudSchema.AppHelpFiles.Contains(path) && (DeckMemoryCloudSchema.FileRow(path) != row || path.StartsWith("archive/backups/", StringComparison.Ordinal) && path.EndsWith(".db", StringComparison.Ordinal)))
        throw new CloudFailure("unsupported_format");
    }
    else if (!p.Key.StartsWith("row/", StringComparison.Ordinal) && !p.Key.StartsWith("backup/", StringComparison.Ordinal)) throw new CloudFailure("unsupported_format");
    return p;
  }

  /// Swift's `String(Double)`: the shortest text that reads back the same, exponent form below 1e-4 and from 2^53
  /// upward written as Swift does (`1e-05`, `1e+16`), integral values with `.0`.
  public static string SwiftDouble(double value)
  {
    if (!double.IsFinite(value)) throw new CloudFailure("invalid_request");
    if (value == 0) return double.IsNegative(value) ? "-0.0" : "0.0";
    var abs = Math.Abs(value);
    var r = value.ToString("R", CultureInfo.InvariantCulture);
    if (abs < 1e-4 || abs >= 1e16)
    {
      // The shortest digits R chose, whatever form it printed them in, rewritten as d.ddde±XX.
      var text = r.TrimStart('-');
      var exponent = 0;
      if (text.IndexOf('E') is >= 0 and var at) { exponent = int.Parse(text[(at + 1)..], CultureInfo.InvariantCulture); text = text[..at]; }
      var point = text.IndexOf('.');
      var whole = point < 0 ? text : text[..point];
      var digits = (whole + (point < 0 ? "" : text[(point + 1)..]));
      exponent += whole.Length - 1;
      var lead = digits.TakeWhile(c => c == '0').Count();
      digits = digits[lead..].TrimEnd('0');
      exponent -= lead;
      if (digits.Length == 0) digits = "0";
      var mantissa = digits.Length == 1 ? digits : digits[0] + "." + digits[1..];
      return (value < 0 ? "-" : "") + mantissa + "e" + (exponent < 0 ? "-" : "+") + Math.Abs(exponent).ToString("00", CultureInfo.InvariantCulture);
    }
    if (r.Contains('E'))
    {
      // R chose exponent form inside Swift's decimal range: expand it.
      r = decimal.Parse(r, NumberStyles.Float, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);
    }
    return r.Contains('.') ? r : r + ".0";
  }
}

/// M4b: which of two versions of one shared value is shown. A PURE function of the two (DeckMemoryCloudMerge.winner):
/// 1. a descendant beats its ancestor; 2. a baseline loses to any unrelated non-baseline; 3. otherwise the newer stamp
/// wins (between two baselines the OLDER); 4. equal stamps: the larger op id.
public sealed record CloudMemoryRevision(string StoreId, string Version, long Stamp, bool Baseline, string OpId, IReadOnlySet<string> Ancestors)
{
  public static CloudMemoryRevision Winner(CloudMemoryRevision a, CloudMemoryRevision b)
  {
    if (a.Version == b.Version) return a;
    if (a.Ancestors.Contains(b.Version)) return a;
    if (b.Ancestors.Contains(a.Version)) return b;
    if (a.Baseline != b.Baseline) return a.Baseline ? b : a;
    if (a.Stamp != b.Stamp) return (a.Stamp > b.Stamp) != a.Baseline ? a : b;
    return string.CompareOrdinal(a.OpId, b.OpId) > 0 ? a : b;
  }
}
