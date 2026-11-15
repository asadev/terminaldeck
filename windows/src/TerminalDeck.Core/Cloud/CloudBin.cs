using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// The keeper and its Bin, ported from the Mac (td-mac-next2 BackendCloudVersionKeeper.swift, the Bin half of
// BackendCloudFolderRules.swift `CloudFileDeleteRecords`). One per signed-in account on this PC:
// `<account>\archive\versions\keeper.json` (the index) and `<kind>\<sha256>` beside it (the content, once per content).
// - A removed item goes to the Bin for 30 days from when THIS PC put it there, AI removals included; then the sweep
//   drops it. The same item removed again replaces its entry; the earlier content stays as a kept version.
// - Putting back takes the item out of the Bin; its content stays a kept version for its 30 days, so a put-back never
//   loses the text it replaces.
// - Groups: each Bin entry remembers the group it went in with (one press, tool call or AI command); the page lists
//   groups (who, which device, when, how many) with one "Put back all". Entries from before the rule get a day group.
// - BY HAND ONLY: no AI tool lists, puts back, empties or deletes from the Bin (the owners expose these to the page only).
// - Never sent, never inside a folder that travels, never read as memory.

public sealed class CloudBin
{
  public const long KeptFor = CloudBinGroup.RetentionMilliseconds;

  /// One kept version. `ItemKey` and `Sha256` are never shown.
  public sealed record Kept(string ItemKey, string Kind, string Name, string? Place, long At, string Device, long Bytes, string Sha256, long KeptUntil);

  /// One Bin entry. `Path` is where the item lived (never shown). `Shown` false: a move kept 30 days, not listed.
  public sealed record Binned(string ItemKey, string Kind, string Name, string? Place, string Path, long RemovedAt, string Device, long Bytes, string Sha256,
    long KeptUntil, bool Shown);

  private sealed class Index
  {
    public List<StoredKept> Versions { get; set; } = [];
    public Dictionary<string, StoredBin> Bin { get; set; } = [];
  }
  private sealed class StoredKept
  {
    public string ItemKey { get; set; } = ""; public string Kind { get; set; } = ""; public string Name { get; set; } = ""; public string? Place { get; set; }
    public long At { get; set; } public string Device { get; set; } = ""; public long Bytes { get; set; } public string Sha256 { get; set; } = ""; public long KeptUntil { get; set; }
    public Kept Value => new(ItemKey, Kind, Name, Place, At, Device, Bytes, Sha256, KeptUntil);
  }
  private sealed class StoredBin
  {
    public string Kind { get; set; } = ""; public string Name { get; set; } = ""; public string? Place { get; set; } public string Path { get; set; } = "";
    public long RemovedAt { get; set; } public string Device { get; set; } = ""; public long Bytes { get; set; } public string Sha256 { get; set; } = "";
    public long KeptUntil { get; set; } public bool Shown { get; set; }
    public StoredGroup? Group { get; set; }
  }
  private sealed class StoredGroup
  {
    public string Id { get; set; } = ""; public string By { get; set; } = ""; public string MacName { get; set; } = ""; public string? Session { get; set; }
    public string? Agent { get; set; } public long At { get; set; } public string Era { get; set; } = "current";
    public List<StoredItem> Items { get; set; } = [];
  }
  private sealed class StoredItem { public string Id { get; set; } = ""; public string Kind { get; set; } = ""; public string Name { get; set; } = ""; public string? Place { get; set; } }

  private readonly string root;
  private readonly CloudFileSlot slot;
  private Index index;

  public CloudBin(string root)
  {
    this.root = root;
    slot = new CloudFileSlot(System.IO.Path.Combine(root, "keeper.json"));
    index = slot.Read() is { } bytes ? JsonSerializer.Deserialize<Index>(bytes) ?? new Index() : new Index();
  }
  /// `<account>\archive\versions`: ONE keeper per account, shared by every kind's owner (the same instance for the same
  /// folder, so two owners never overwrite each other's index).
  public static CloudBin ForAccount(string accountFolder) => Shared(System.IO.Path.Combine(accountFolder, "archive", "versions"));
  private static readonly Dictionary<string, CloudBin> shared = new(StringComparer.OrdinalIgnoreCase);
  public static CloudBin Shared(string root)
  {
    var full = System.IO.Path.GetFullPath(root);
    lock (shared) return shared.TryGetValue(full, out var held) ? held : shared[full] = new CloudBin(full);
  }
  private readonly object gate = new();
  public string Root => root;
  private void Save() => slot.Write(JsonSerializer.SerializeToUtf8Bytes(index));

  public static bool IsSha(string text) => text.Length == 64 && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
  private static bool SafeKind(string kind) => kind.Length > 0 && kind.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
  public string ContentPath(string kind, string sha256) => System.IO.Path.Combine(root, kind, sha256);

  /// The content file alone, checked by fingerprint, durable and read back before any caller removes the original.
  public void Store(string kind, string sha256, byte[] content)
  {
    if (!IsSha(sha256) || !SafeKind(kind)) throw new CloudFailure("invalid_request");
    var target = ContentPath(kind, sha256);
    if (File.Exists(target) && CloudBytes.Sha256Hex(File.ReadAllBytes(target)) == sha256) return;
    new CloudFileSlot(target).Write(content);
    if (!File.Exists(target) || CloudBytes.Sha256Hex(File.ReadAllBytes(target)) != sha256) throw new CloudFailure("checksum_mismatch");
  }
  /// The kept bytes, or null when gone or no longer matching their fingerprint.
  public byte[]? Content(string kind, string sha256)
  {
    if (!IsSha(sha256) || !SafeKind(kind)) return null;
    var path = ContentPath(kind, sha256);
    try { return File.Exists(path) && File.ReadAllBytes(path) is var held && CloudBytes.Sha256Hex(held) == sha256 ? held : null; }
    catch (IOException) { return null; }
  }

  // ---- Kept versions ----

  /// Keeps `content` (once per content) for 30 days from `now`; keeping the same content for the same item again only
  /// moves its date forward. Returns the date it is kept until.
  public long Keep(string kind, string itemKey, string name, string? place, long at, string device, byte[] content, long now)
  {
    lock (gate)
    {
      var sha = CloudBytes.Sha256Hex(content);
      Store(kind, sha, content);
      var until = now + KeptFor;
      var held = index.Versions.FirstOrDefault(v => v.ItemKey == itemKey && v.Sha256 == sha);
      if (held is null) index.Versions.Add(new StoredKept { ItemKey = itemKey, Kind = kind, Name = name, Place = place, At = at, Device = device, Bytes = content.Length, Sha256 = sha, KeptUntil = until });
      else held.KeptUntil = Math.Max(held.KeptUntil, until);
      Save();
      return Math.Max(held?.KeptUntil ?? until, until);
    }
  }
  /// What is kept for one item, newest first.
  public IReadOnlyList<Kept> Versions(string itemKey) { lock (gate) return index.Versions.Where(v => v.ItemKey == itemKey).OrderByDescending(v => v.At).ThenBy(v => v.Sha256, StringComparer.Ordinal).Select(v => v.Value).ToArray(); }
  public IReadOnlyList<Kept> VersionsOfKind(string kind) { lock (gate) return index.Versions.Where(v => v.Kind == kind).OrderByDescending(v => v.At).ThenBy(v => v.Sha256, StringComparer.Ordinal).Select(v => v.Value).ToArray(); }

  // ---- The Bin ----

  private Binned Value(string itemKey, StoredBin b) => new(itemKey, b.Kind, b.Name, b.Place, b.Path, b.RemovedAt, b.Device, b.Bytes, b.Sha256, b.KeptUntil, b.Shown);

  /// Puts content in the Bin for 30 days from NOW (`removedAt` is only shown). The same item removed again replaces
  /// its entry; the earlier content stays as a kept version. `group`: the group this removal belongs to (one item);
  /// null keeps the entry's earlier group, or none (a day group "Before the new rule" is made when listed).
  public Binned Put(string kind, string itemKey, string name, string? place, string path, long removedAt, string device, byte[] content, bool shown, long now,
    CloudBinGroup? group = null)
  {
    lock (gate)
    {
      var sha = CloudBytes.Sha256Hex(content);
      Store(kind, sha, content);
      if (index.Bin.TryGetValue(itemKey, out var earlier) && earlier.Sha256 != sha && Content(earlier.Kind, earlier.Sha256) is { } held)
        Keep(earlier.Kind, itemKey, earlier.Name, earlier.Place, earlier.RemovedAt, earlier.Device, held, now);
      var until = now + KeptFor;
      var entry = new StoredBin
      {
        Kind = kind, Name = name, Place = place, Path = path, RemovedAt = removedAt, Device = device, Bytes = content.Length, Sha256 = sha,
        KeptUntil = Math.Max(earlier?.KeptUntil ?? 0, until), Shown = shown || earlier?.Shown == true,
        Group = group is null ? earlier?.Group : Stored(group)
      };
      index.Bin[itemKey] = entry;
      Save();
      return Value(itemKey, entry);
    }
  }
  public Binned? Get(string itemKey) { lock (gate) return index.Bin.TryGetValue(itemKey, out var b) ? Value(itemKey, b) : null; }
  /// The Bin as he sees it: removals only (moves are kept but not listed), newest first.
  public IReadOnlyList<Binned> List(string kind) { lock (gate) return index.Bin.Where(b => b.Value.Kind == kind && b.Value.Shown).Select(b => Value(b.Key, b.Value)).OrderByDescending(b => b.RemovedAt).ThenBy(b => b.ItemKey, StringComparer.Ordinal).ToArray(); }
  /// Every Bin item of one kind, listed or not.
  public IReadOnlyList<Binned> All(string kind) { lock (gate) return index.Bin.Where(b => b.Value.Kind == kind).Select(b => Value(b.Key, b.Value)).OrderByDescending(b => b.RemovedAt).ThenBy(b => b.ItemKey, StringComparer.Ordinal).ToArray(); }
  /// Out of the Bin (put back, or a newer edit brought it back); the content stays a kept version for its 30 days.
  public void Take(string itemKey, long now)
  {
    lock (gate)
    {
      if (!index.Bin.TryGetValue(itemKey, out var item)) return;
      if (Content(item.Kind, item.Sha256) is { } held) Keep(item.Kind, itemKey, item.Name, item.Place, item.RemovedAt, item.Device, held, now);
      index.Bin.Remove(itemKey);
      Save();
    }
  }
  /// The person's "Delete for good" (page only). The content goes when nothing else names it.
  public void DeleteForGood(string itemKey)
  {
    lock (gate)
    {
      if (!index.Bin.Remove(itemKey, out var item)) return;
      Save();
      DropUnnamed([(item.Kind, item.Sha256)]);
    }
  }

  /// The 30-day keeper: every version and Bin item kept until `before` or earlier, and each content nothing names.
  public int Sweep(long before)
  {
    lock (gate)
    {
      var gone = new List<(string, string)>();
      foreach (var v in index.Versions.Where(v => v.KeptUntil <= before).ToArray()) { index.Versions.Remove(v); gone.Add((v.Kind, v.Sha256)); }
      foreach (var (key, b) in index.Bin.Where(b => b.Value.KeptUntil <= before).ToArray()) { index.Bin.Remove(key); gone.Add((b.Kind, b.Sha256)); }
      if (gone.Count == 0) return 0;
      Save();
      DropUnnamed(gone);
      return gone.Count;
    }
  }
  private void DropUnnamed(IEnumerable<(string Kind, string Sha)> pairs)
  {
    foreach (var (kind, sha) in pairs.Distinct())
    {
      if (index.Versions.Any(v => v.Kind == kind && v.Sha256 == sha) || index.Bin.Values.Any(b => b.Kind == kind && b.Sha256 == sha)) continue;
      try { File.Delete(ContentPath(kind, sha)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
  }

  // ---- Groups ----

  private static StoredGroup Stored(CloudBinGroup g) => new()
  {
    Id = g.Id, By = CloudDeleteText.Raw(g.By), MacName = g.MacName, Session = g.Session, Agent = g.Agent, At = g.At, Era = CloudFileDeleteRecords.EraRaw(g.Era),
    Items = g.Items.Select(i => new StoredItem { Id = i.Id, Kind = i.Kind, Name = i.Name, Place = i.Place }).ToList()
  };
  private static CloudBinGroup? Group(StoredGroup? g) => g is null ? null : new(g.Id, CloudDeleteText.By(g.By) ?? CloudDeleteBy.Person, g.MacName, g.Session, g.Agent, g.At,
    g.Items.Select(i => new CloudDeleteItem(i.Id, i.Kind, i.Name, i.Place)).ToArray(),
    g.Era switch { "olderVersion" => CloudBinEra.OlderVersion, "beforeNewRule" => CloudBinEra.BeforeNewRule, _ => CloudBinEra.Current });
  /// The group an entry went in with, or null (an entry from before the rule).
  public CloudBinGroup? GroupOf(string itemKey) { lock (gate) return index.Bin.TryGetValue(itemKey, out var b) ? Group(b.Group) : null; }

  /// The Bin of one kind as the page shows it: one row per group, newest first. `item` turns an entry into its page
  /// item; `deviceName` turns a device id into its name (null: "Another of your devices").
  public IReadOnlyList<CloudBinGroup> Groups(string kind, Func<Binned, CloudDeleteItem?> item, Func<string, string?> deviceName)
  {
    lock (gate)
    {
      var groups = new List<CloudBinGroup>();
      foreach (var b in List(kind))
      {
        if (GroupOf(b.ItemKey) is { } g) { groups.Add(g); continue; }
        if (item(b) is not { } shown) continue;
        groups.Add(CloudFileDeleteRecords.LegacyGroup(shown, b.Device, deviceName(b.Device.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice, b.RemovedAt, CloudBinEra.BeforeNewRule));
      }
      return CloudFileDeleteRecords.Merge(groups);
    }
  }
}
