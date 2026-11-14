using System.Text;

namespace TerminalDeck.Core.Cloud;

// Every read and every write the instruction-file sync makes in a folder a person owns, with the Mac's rules
// (BackendCloudBootFilesDisk.swift) in Windows terms:
// - The folder itself is the person's choice. BELOW it no link (symbolic link, junction, any reparse point) is followed.
// - A name must be on the disk exactly as spelled. A name that differs only in letter case or in how an accented letter
//   is stored (a "twin") stops the read or the write; this is checked from the folder's own listing.
// - A new file gets its name only where nothing is (a move that never replaces).
// - An existing file is replaced only if it still holds the expected bytes: swapped in, and what came out is checked;
//   if that is not what was expected it is swapped back, so a save that landed in between is never lost.
// - Nothing is run, and nothing is ever deleted from the person's folder.

public static class CloudBootFilesDisk
{
  /// What stands at a path: nothing, a file's bytes, or why it was not read (link, twin, in-the-way, too-large, name,
  /// unreadable, unreachable).
  public sealed record Found(byte[]? Bytes, string? Blocked)
  {
    public static Found Absent { get; } = new(null, null);
    public bool IsAbsent => Bytes is null && Blocked is null;
  }
  /// Why a write did not happen: link, twin, in-the-way, changed, name, unreadable, unreachable, unwritable.
  public sealed class Stop(string reason) : Exception("The instruction file was not written: " + reason) { public string Reason { get; } = reason; }

  /// One boot file found by a walk: its path inside the place, size and last-write time (UTC ticks).
  public sealed record Entry(string Relative, long Length, long ModifiedTicks);
  public sealed class Walk
  {
    public List<Entry> Files { get; } = [];
    /// Left out on purpose, by short code: link, too-large, not-text, hidden, never, rebuildable.
    public Dictionary<string, int> Excluded { get; } = new(StringComparer.Ordinal);
    /// Should have been read and was not: unreadable, unreachable, twin, name, too-many, too-deep.
    public Dictionary<string, int> Gaps { get; } = new(StringComparer.Ordinal);
    internal void Exclude(string code) => Excluded[code] = Excluded.GetValueOrDefault(code) + 1;
    internal void Gap(string code) => Gaps[code] = Gaps.GetValueOrDefault(code) + 1;
  }

  private static string Fold(string name) => name.Normalize(NormalizationForm.FormC).ToUpperInvariant();
  private static bool IsLink(FileSystemInfo info) => (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.LinkTarget is not null;

  private enum Lookup { Exact, Twin, Absent }
  private static Lookup? Find(string folder, string name, out FileSystemInfo? found)
  {
    found = null;
    IEnumerable<FileSystemInfo> listed;
    try { listed = new DirectoryInfo(folder).EnumerateFileSystemInfos().ToArray(); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return null; }
    var wanted = Fold(name);
    var twin = false;
    foreach (var info in listed)
    {
      if (string.Equals(info.Name, name, StringComparison.Ordinal)) { found = info; return Lookup.Exact; }
      if (Fold(info.Name) == wanted) twin = true;
    }
    return twin ? Lookup.Twin : Lookup.Absent;
  }

  /// Opens the folders named by `parts` below `root`, one by one, never through a link. Returns the last folder, or
  /// null when one is missing and `create` is false.
  private static string? Descend(string root, IEnumerable<string> parts, bool create)
  {
    var current = root;
    foreach (var name in parts)
    {
      FileSystemInfo? info;
      switch (Find(current, name, out info))
      {
        case null: throw new Stop("unreadable");
        case Lookup.Twin: throw new Stop("twin");
        case Lookup.Absent:
          if (!create) return null;
          try { Directory.CreateDirectory(Path.Combine(current, name)); }
          catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { throw new Stop("unwritable"); }
          if (Find(current, name, out info) != Lookup.Exact || info is not DirectoryInfo) throw new Stop("unwritable");
          break;
      }
      if (IsLink(info!)) throw new Stop("link");
      if (info is not DirectoryInfo) throw new Stop("in-the-way");
      current = info.FullName;
    }
    return current;
  }
  private static string Root(string root)
  {
    if (!Directory.Exists(root)) throw new Stop("unreachable");
    return root;
  }
  private static (string Folder, string Name) Split(string relative)
  {
    if (CloudBootFilesFormat.Parts(relative) is not { Length: > 0 } parts || parts[^1].Length == 0) throw new Stop("name");
    return (string.Join('/', parts[..^1]), parts[^1]);
  }

  public static Found Read(string root, string relative, int cap = CloudBootFilesFormat.MaximumFileBytes)
  {
    try
    {
      var (folderPart, name) = Split(relative);
      var folder = Descend(Root(root), folderPart.Length == 0 ? [] : folderPart.Split('/'), create: false);
      return folder is null ? Found.Absent : ReadIn(folder, name, cap);
    }
    catch (Stop stop) { return new(null, stop.Reason); }
  }
  private static Found ReadIn(string folder, string name, int cap)
  {
    FileSystemInfo? info;
    switch (Find(folder, name, out info))
    {
      case null: return new(null, "unreadable");
      case Lookup.Absent: return Found.Absent;
      case Lookup.Twin: return new(null, "twin");
    }
    if (IsLink(info!)) return new(null, "link");
    if (info is not FileInfo file) return new(null, "in-the-way");
    if (file.Length > cap) return new(null, "too-large");
    try
    {
      var bytes = File.ReadAllBytes(file.FullName);
      return bytes.Length <= cap ? new(bytes, null) : new(null, "too-large");
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return new(null, "unreadable"); }
  }

  /// The file's last-write time in ms since 1970 (UTC), or null.
  public static long? ModifiedMs(string root, string relative)
  {
    try
    {
      var path = Path.Combine([root, .. relative.Split('/')]);
      return File.Exists(path) ? new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds() : null;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
  /// Gives the file a version's time (never later than `now`), so recording it does not make it look newer than it is.
  public static void SetModified(string root, string relative, long at)
  {
    try { File.SetLastWriteTimeUtc(Path.Combine([root, .. relative.Split('/')]), DateTimeOffset.FromUnixTimeMilliseconds(at).UtcDateTime); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
  }

  private static string Stage(string folder, byte[] bytes)
  {
    var staged = Path.Combine(folder, ".td-cloud-" + Guid.NewGuid().ToString("N"));
    try
    {
      using var stream = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None);
      stream.Write(bytes);
      stream.Flush(flushToDisk: true);
      return staged;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
    {
      TryDelete(staged);
      throw new Stop("unwritable");
    }
  }
  private static void TryDelete(string path)
  {
    try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
  }

  /// A NEW file. Stops with `changed` when anything already holds the name, `twin` when a twin does.
  public static void Create(string root, string relative, byte[] bytes)
  {
    var (folderPart, name) = Split(relative);
    var folder = Descend(Root(root), folderPart.Length == 0 ? [] : folderPart.Split('/'), create: true)!;
    switch (Find(folder, name, out _))
    {
      case null: throw new Stop("unreadable");
      case Lookup.Twin: throw new Stop("twin");
      case Lookup.Exact: throw new Stop("changed");
    }
    var staged = Stage(folder, bytes);
    try { File.Move(staged, Path.Combine(folder, name), overwrite: false); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
    {
      TryDelete(staged);
      throw new Stop(Find(folder, name, out _) == Lookup.Absent ? "name" : "changed");
    }
    if (ReadIn(folder, name, bytes.Length) is not { Bytes: { } written } || !written.AsSpan().SequenceEqual(bytes)) throw new Stop("changed");
  }

  /// Replaces a file whose bytes have the fingerprint `expecting`, and nothing else. Returns the bytes replaced.
  public static byte[] Replace(string root, string relative, byte[] bytes, string expecting)
  {
    var (folderPart, name) = Split(relative);
    var folder = Descend(Root(root), folderPart.Length == 0 ? [] : folderPart.Split('/'), create: false) ?? throw new Stop("changed");
    // Looked at first: a link, a folder or other bytes under the name end it here, before anything is staged.
    var current = ReadIn(folder, name, CloudBootFilesFormat.MaximumFileBytes);
    if (current.Blocked is { } blocked) throw new Stop(blocked == "too-large" ? "changed" : blocked);
    if (current.Bytes is not { } held || CloudMemoryFormat.Hash(held) != expecting) throw new Stop("changed");
    var target = Path.Combine(folder, name);
    var staged = Stage(folder, bytes);
    var backup = Path.Combine(folder, ".td-cloud-" + Guid.NewGuid().ToString("N") + ".old");
    try { File.Replace(staged, target, backup, ignoreMetadataErrors: true); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or PlatformNotSupportedException)
    {
      TryDelete(staged);
      throw new Stop("unwritable");
    }
    // `backup` now holds what was there. Only the expected bytes may go.
    byte[]? previous = null;
    try { previous = File.ReadAllBytes(backup); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    if (previous is not null && CloudMemoryFormat.Hash(previous) == expecting)
    {
      TryDelete(backup);
      return previous;
    }
    // An edit landed in between: put it back exactly as it was; the bytes from the Cloud stay where they were kept.
    var undone = Path.Combine(folder, ".td-cloud-" + Guid.NewGuid().ToString("N") + ".new");
    try { File.Replace(backup, target, undone, ignoreMetadataErrors: true); TryDelete(undone); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or PlatformNotSupportedException) { }
    throw new Stop("changed");
  }

  /// The boot files of one place by the list: only the listed top-level files and the listed folders are opened.
  public static Walk Scan(string root, CloudBootFilesPlaceKind kind)
  {
    var walk = new Walk();
    if (!Directory.Exists(root)) { walk.Gap("unreachable"); return walk; }
    foreach (var name in CloudBootFilesFormat.Files(kind))
    {
      FileSystemInfo? info;
      switch (Find(root, name, out info))
      {
        case null: walk.Gap("unreadable"); break;
        case Lookup.Twin: walk.Gap("twin"); break;
        case Lookup.Exact: Take(info!, name, kind, walk); break;
      }
    }
    foreach (var folder in CloudBootFilesFormat.Folders(kind))
    {
      try
      {
        if (Descend(root, folder.Split('/'), create: false) is { } opened) ScanFolder(opened, folder + "/", kind, 1, walk);
      }
      catch (Stop stop)
      {
        if (stop.Reason == "link") walk.Exclude("link"); else walk.Gap(stop.Reason);
      }
    }
    return walk;
  }
  private static void ScanFolder(string folder, string prefix, CloudBootFilesPlaceKind kind, int depth, Walk walk)
  {
    FileSystemInfo[] listed;
    try { listed = new DirectoryInfo(folder).EnumerateFileSystemInfos().OrderBy(i => i.Name, StringComparer.Ordinal).ToArray(); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { walk.Gap("unreadable"); return; }
    var folds = new HashSet<string>(StringComparer.Ordinal);
    foreach (var info in listed)
    {
      var relative = prefix + info.Name;
      if (!folds.Add(Fold(info.Name))) { walk.Gap("twin"); continue; }
      if (info is not DirectoryInfo || IsLink(info)) { Take(info, relative, kind, walk); continue; }
      if (info.Name.StartsWith('.')) { walk.Exclude("hidden"); continue; }
      var lower = info.Name.ToLowerInvariant();
      if (CloudBootFilesFormat.NeverFolderNames.Contains(lower)) { walk.Exclude("never"); continue; }
      if (CloudBootFilesFormat.RebuildableFolderNames.Contains(lower)) { walk.Exclude("rebuildable"); continue; }
      if (depth >= CloudBootFilesFormat.MaximumFolderDepth) { walk.Gap("too-deep"); continue; }
      ScanFolder(info.FullName, relative + "/", kind, depth + 1, walk);
    }
  }
  private static void Take(FileSystemInfo info, string relative, CloudBootFilesPlaceKind kind, Walk walk)
  {
    if (CloudBootFilesFormat.Refusal(kind, relative) is { } refusal)
    {
      switch (refusal)
      {
        case CloudBootFilesRefusal.Hidden: walk.Exclude("hidden"); break;
        case CloudBootFilesRefusal.Never: walk.Exclude("never"); break;
        case CloudBootFilesRefusal.Rebuildable: walk.Exclude("rebuildable"); break;
        default: walk.Gap("name"); break;
      }
      return;
    }
    if (IsLink(info)) { walk.Exclude("link"); return; }
    if (info is not FileInfo file) { walk.Exclude("not-text"); return; }
    if (walk.Files.Count >= CloudBootFilesFormat.MaximumFilesPerPlace) { walk.Gap("too-many"); return; }
    if (file.Length > CloudBootFilesFormat.MaximumFileBytes) { walk.Exclude("too-large"); return; }
    walk.Files.Add(new(relative, file.Length, file.LastWriteTimeUtc.Ticks));
  }
}
