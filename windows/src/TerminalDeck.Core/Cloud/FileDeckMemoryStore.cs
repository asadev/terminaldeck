using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// 7C-1: this PC's copy of Deck Memory for one signed-in account. The notes and other memory files are ordinary files
// under `<folder>/files` (the same relative paths as on the Mac, with '/' turned into the Windows separator); the
// labels (the memory tables) are one JSON file per table under `<folder>/tables`, written whole by atomic replace when
// the sync engine settles a pack. No SQLite (see CloudSyncStore). There is no remove: sync on Windows never deletes.

public sealed class FileDeckMemoryStore : IDeckMemoryCloudStore
{
  private sealed class Table
  {
    public List<DeckMemoryRow> Rows = [];
    public Dictionary<string, int> ByKey = new(StringComparer.Ordinal);
    public Dictionary<string, int>? ByPath;
    public bool Dirty;
  }
  private sealed class Meta { public string StoreId { get; set; } = ""; public Dictionary<string, long> Sequences { get; set; } = []; }

  private readonly string folder, filesRoot;
  private readonly Dictionary<string, Table> tables = new(StringComparer.Ordinal);
  private readonly Meta meta;
  private bool metaDirty;
  public string StoreId => meta.StoreId;
  /// The memory folder itself (the notes), for the page and the person.
  public string FilesFolder => filesRoot;

  private FileDeckMemoryStore(string folder)
  {
    this.folder = folder;
    filesRoot = Path.Combine(folder, "files");
    var slot = new CloudFileSlot(Path.Combine(folder, "store.json"));
    meta = slot.Read() is { } bytes ? JsonSerializer.Deserialize<Meta>(bytes) ?? new Meta() : new Meta();
    if (!Guid.TryParse(meta.StoreId, out _))
    {
      meta.StoreId = Guid.NewGuid().ToString();
      slot.Write(JsonSerializer.SerializeToUtf8Bytes(meta));
    }
  }
  public static FileDeckMemoryStore At(string folder) => new(folder);

  // ---- Tables ----

  private static string KeyText(IEnumerable<DeckMemoryCell> keys) => Encoding.UTF8.GetString(CloudCanonical.Encode(CloudJson.Arr(keys.Select(k => k.ToJson()))));
  private static string CellText(DeckMemoryCell cell) => cell.Type + "\n" + cell.Value;
  private string TablePath(string name) => Path.Combine(folder, "tables", name + ".json");

  private Table Load(string name)
  {
    if (tables.TryGetValue(name, out var loaded)) return loaded;
    var t = DeckMemoryCloudSchema.Table(name);
    var table = new Table();
    if (new CloudFileSlot(TablePath(name)).Read() is { } bytes)
      foreach (var flat in JsonSerializer.Deserialize<List<string?[]>>(bytes) ?? [])
      {
        if (flat.Length != 2 * t.Columns.Count) throw new CloudFailure("unsupported_format");
        var cells = new DeckMemoryCell[t.Columns.Count];
        for (var i = 0; i < cells.Length; i++) cells[i] = new DeckMemoryCell(flat[2 * i] ?? throw new CloudFailure("unsupported_format"), flat[2 * i + 1]);
        Add(table, t, new DeckMemoryRow(name, cells));
      }
    tables[name] = table;
    return table;
  }
  private static void Add(Table table, DeckMemoryTable t, DeckMemoryRow row)
  {
    table.ByKey[KeyText(t.Keys.Select(k => row.Cells[t.Index(k)]))] = table.Rows.Count;
    table.Rows.Add(row);
    if (table.ByPath is { } byPath && t.Index("path") is >= 0 and var pi) byPath.TryAdd(CellText(row.Cells[pi]), table.Rows.Count - 1);
  }

  public IReadOnlyList<DeckMemoryRow> Rows(string table) => Load(table).Rows.ToArray();
  public DeckMemoryRow? Find(string table, IReadOnlyList<DeckMemoryCell> keys) =>
    Load(table) is var t && t.ByKey.TryGetValue(KeyText(keys), out var at) ? t.Rows[at] : null;
  public DeckMemoryRow? FindWhere(string table, string column, DeckMemoryCell value)
  {
    var t = DeckMemoryCloudSchema.Table(table);
    var i = t.Index(column);
    if (i < 0) return null;
    var loaded = Load(table);
    if (column != "path") return loaded.Rows.FirstOrDefault(r => r.Cells[i] == value);
    if (loaded.ByPath is null)
    {
      loaded.ByPath = new(StringComparer.Ordinal);
      for (var n = 0; n < loaded.Rows.Count; n++) loaded.ByPath.TryAdd(CellText(loaded.Rows[n].Cells[i]), n);
    }
    return loaded.ByPath.TryGetValue(CellText(value), out var at) ? loaded.Rows[at] : null;
  }
  public void PutRow(DeckMemoryRow row, IReadOnlyList<DeckMemoryCell>? replacing)
  {
    var t = DeckMemoryCloudSchema.Table(row.Table);
    if (row.Cells.Count != t.Columns.Count) throw new CloudFailure("invalid_request");
    var table = Load(row.Table);
    var keys = KeyText(replacing ?? t.Keys.Select(k => row.Cells[t.Index(k)]).ToArray());
    if (table.ByKey.TryGetValue(keys, out var at))
    {
      table.ByKey.Remove(keys);
      table.Rows[at] = row;
      table.ByKey[KeyText(t.Keys.Select(k => row.Cells[t.Index(k)]))] = at;
      table.ByPath = null;
    }
    else Add(table, t, row);
    table.Dirty = true;
    if (t.IntegerKey && row.Cells[t.Index("id")].AsInteger is { } id && id > meta.Sequences.GetValueOrDefault(row.Table)) { meta.Sequences[row.Table] = id; metaDirty = true; }
  }
  public long AllocateInteger(string table)
  {
    var t = DeckMemoryCloudSchema.Table(table);
    var highest = Load(table).Rows.Select(r => r.Cells[t.Index("id")].AsInteger ?? 0).DefaultIfEmpty(0).Max();
    var next = Math.Max(highest, meta.Sequences.GetValueOrDefault(table)) + 1;
    meta.Sequences[table] = next; metaDirty = true;
    return next;
  }
  public void Flush()
  {
    foreach (var (name, table) in tables.Where(t => t.Value.Dirty))
    {
      var flat = table.Rows.Select(r => r.Cells.SelectMany(c => new[] { c.Type, c.Value }).ToArray()).ToList();
      new CloudFileSlot(TablePath(name)).Write(JsonSerializer.SerializeToUtf8Bytes(flat));
      table.Dirty = false;
    }
    if (metaDirty) { new CloudFileSlot(Path.Combine(folder, "store.json")).Write(JsonSerializer.SerializeToUtf8Bytes(meta)); metaDirty = false; }
  }

  // ---- Files ----

  private static bool Skipped(FileSystemInfo info) => info.Name.StartsWith('.') || info.Attributes.HasFlag(FileAttributes.ReparsePoint);

  public IReadOnlyList<DeckMemoryFileInfo> ListFiles()
  {
    var found = new List<DeckMemoryFileInfo>();
    var root = new DirectoryInfo(filesRoot);
    if (!root.Exists) return found;
    var folders = new Stack<(DirectoryInfo Folder, string Relative)>([(root, "")]);
    while (folders.Count > 0)
    {
      var (current, relative) = folders.Pop();
      foreach (var item in current.EnumerateFileSystemInfos())
      {
        // Hidden names and links are never listed (the Mac's M5/M6: they stay on this device and never travel).
        if (Skipped(item)) continue;
        var path = relative.Length == 0 ? item.Name : relative + "/" + item.Name;
        if (item is DirectoryInfo sub) folders.Push((sub, path));
        else if (item is FileInfo file) found.Add(new(path, file.Length, file.LastWriteTimeUtc.Ticks));
      }
    }
    return found;
  }

  /// The full path for `path`, refusing anything outside the memory folder or through a link.
  private string Full(string path)
  {
    if (!DeckMemoryCloudSchema.SafePath(path)) throw new CloudFailure("invalid_request");
    var full = filesRoot;
    foreach (var part in path.Split('/'))
    {
      full = Path.Combine(full, part);
      var info = new FileInfo(full);
      if (info.Exists || Directory.Exists(full))
        if (File.GetAttributes(full).HasFlag(FileAttributes.ReparsePoint)) throw new CloudFailure("unsafe_configuration");
    }
    return full;
  }
  public byte[]? ReadFile(string path)
  {
    var full = Full(path);
    return File.Exists(full) ? File.ReadAllBytes(full) : null;
  }
  public void WriteFile(string path, byte[] bytes)
  {
    if (WindowsName(path) != path) throw new CloudFailure("invalid_request");
    new CloudFileSlot(Full(path)).Write(bytes);
  }

  private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
  {
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³"
  };
  /// The nearest name Windows can hold: characters it refuses become '_', a name ending in '.' or ' ' gains a '_', a
  /// reserved device name (CON, NUL, COM1 …, with any extension) gains a leading '_'. Unchanged for ordinary names.
  public static string WindowsName(string path) => string.Join('/', path.Split('/').Select(part =>
  {
    var chars = part.Select(c => c < 0x20 || c is '<' or '>' or ':' or '"' or '|' or '?' or '*' ? '_' : c).ToArray();
    var name = new string(chars);
    if (name.EndsWith('.') || name.EndsWith(' ')) name += "_";
    var dot = name.IndexOf('.');
    if (Reserved.Contains((dot < 0 ? name : name[..dot]).TrimEnd(' '))) name = "_" + name;
    return name;
  }));
}
