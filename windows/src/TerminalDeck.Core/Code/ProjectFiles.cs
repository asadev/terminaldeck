using System.Globalization;
using System.Text;

namespace TerminalDeck.Core.Code;

// The Files page's pure half, rule for rule with the Mac's FilesRules.swift.
public sealed record FsEntry(string Name, string RelPath, bool IsDir, bool Symlink = false, bool Blocked = false, bool Ignored = false);
public sealed record DirListing(string RelPath, IReadOnlyList<FsEntry> Entries, bool Truncated = false, string? DefaultFile = null);
public enum FileReadKind { Text, Binary, TooLarge }
public sealed record FileRead(string RelPath, FileReadKind Kind, int Bytes, string Text = "", int Limit = 0);
public sealed record FileMatch(string RelPath, string Name);
public enum TreeRootKind { Loading, Ready, Empty, Error }
public sealed record TreeRootState(TreeRootKind Kind, int Count = 0, string Message = "");
public enum FilesPageLayout { TreeAndViewer, TreeOnly, Blank }

public sealed class FileTreeState
{
  public const string Root = "";
  public Dictionary<string, IReadOnlyList<FsEntry>> Children { get; } = [];
  public HashSet<string> Expanded { get; } = [];
  public HashSet<string> Loading { get; } = [];
  public Dictionary<string, string> Errors { get; } = [];
  public HashSet<string> Truncated { get; } = [];
  public string? Focused { get; set; }

  public void Expand(string dir) => Expanded.Add(dir);
  public void Collapse(string dir) => Expanded.Remove(dir);
  public void LoadStarted(string dir) { Errors.Remove(dir); if (dir != Root) Expanded.Add(dir); Loading.Add(dir); }
  public void Loaded(string dir, DirListing listing)
  {
    Children[dir] = listing.Entries; Loading.Remove(dir);
    if (listing.Truncated) Truncated.Add(dir); else Truncated.Remove(dir);
    if (Focused is null && dir == Root) Focused = listing.Entries.FirstOrDefault()?.RelPath;
  }
  public void Failed(string dir, string message) { Errors[dir] = message; Loading.Remove(dir); Expanded.Remove(dir); }
  public void Reset() { Children.Clear(); Expanded.Clear(); Loading.Clear(); Errors.Clear(); Truncated.Clear(); Focused = null; }

  public TreeRootState RootState =>
    Errors.TryGetValue(Root, out var message) ? new(TreeRootKind.Error, Message: message)
    : !Children.TryGetValue(Root, out var entries) ? new(TreeRootKind.Loading)
    : entries.Count == 0 ? new(TreeRootKind.Empty) : new(TreeRootKind.Ready, entries.Count);

  public sealed record Row(FsEntry Entry, int Depth);
  public IReadOnlyList<Row> Rows
  {
    get
    {
      var rows = new List<Row>();
      void Walk(string dir, int depth)
      {
        foreach (var entry in Children.GetValueOrDefault(dir) ?? [])
        {
          rows.Add(new(entry, depth));
          if (entry.IsDir && Expanded.Contains(entry.RelPath)) Walk(entry.RelPath, depth + 1);
        }
      }
      Walk(Root, 0); return rows;
    }
  }
  public static string Parent(string relPath) => relPath.LastIndexOf('/') is var cut and >= 0 ? relPath[..cut] : Root;

  public enum Toggle { None, Collapse, Expand, Load }
  public Toggle ToggleFor(FsEntry entry) =>
    !entry.IsDir || entry.Blocked ? Toggle.None : Expanded.Contains(entry.RelPath) ? Toggle.Collapse : Children.ContainsKey(entry.RelPath) ? Toggle.Expand : Toggle.Load;

  public enum Key { Down, Up, Right, Left, Home, End, Activate }
  public enum EffectKind { None, Focus, Toggle, Collapse, Activate }
  public sealed record KeyEffect(EffectKind Kind, string? RelPath = null, FsEntry? Entry = null);
  public KeyEffect Effect(Key key)
  {
    var rows = Rows;
    if (rows.Count == 0) return new(EffectKind.None);
    var index = -1; for (var i = 0; i < rows.Count; i++) if (rows[i].Entry.RelPath == Focused) { index = i; break; }
    var entry = index >= 0 ? rows[index].Entry : null;
    KeyEffect At(int i) => new(EffectKind.Focus, rows[Math.Clamp(i, 0, rows.Count - 1)].Entry.RelPath);
    switch (key)
    {
      case Key.Down: return At(index + 1);
      case Key.Up: return At(index == -1 ? 0 : index - 1);
      case Key.Right:
        if (entry is null || !entry.IsDir || entry.Blocked) return new(EffectKind.None);
        return Expanded.Contains(entry.RelPath) ? At(index + 1) : new(EffectKind.Toggle, entry.RelPath, entry);
      case Key.Left:
        if (entry is null) return new(EffectKind.None);
        if (entry.IsDir && Expanded.Contains(entry.RelPath)) return new(EffectKind.Collapse, entry.RelPath);
        var parent = Parent(entry.RelPath);
        return parent == Root ? new(EffectKind.None) : new(EffectKind.Focus, parent);
      case Key.Home: return At(0);
      case Key.End: return At(rows.Count - 1);
      default: return entry is null ? new(EffectKind.None) : new(EffectKind.Activate, entry.RelPath, entry);
    }
  }
}

public static class FilesRules
{
  public const int MaxEntries = 2000;
  public const int MaxReadBytes = 1024 * 1024;
  public const int MaxViewLines = 50_000;
  public const int MaxSearchResults = 200;
  public const string TruncatedLine = "Too many entries — list shortened.";

  public static FilesPageLayout Layout(TreeRootState tree) => tree.Kind switch { TreeRootKind.Empty => FilesPageLayout.Blank, TreeRootKind.Error => FilesPageLayout.TreeOnly, _ => FilesPageLayout.TreeAndViewer };
  public static string BlankReason(string root, bool showIgnored) =>
    showIgnored ? $"Nothing at all in {root}, ignored files included." : $"Nothing in {root} that your .gitignore does not exclude.";
  public static string ListWhat(string dir) => dir.Length == 0 ? "Reading this folder" : "Reading " + dir;
  public static string ReadWhat(string relPath) => "Reading " + Name(relPath);
  public static string RowTitle(FsEntry entry) => entry.Blocked ? entry.Name + " — link leaves the project, or loops" : entry.RelPath;
  public static string Name(string relPath) => relPath.Split('/')[^1];
  public static string ExtensionOf(string relPath)
  {
    var name = Name(relPath); var dot = name.LastIndexOf('.');
    return dot > 0 ? name[(dot + 1)..] : "";
  }
  public static string FormatBytes(long bytes) =>
    bytes < 1024 ? $"{bytes} B" : bytes < 1024 * 1024 ? (bytes / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " KB" : (bytes / (1024.0 * 1024)).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
  private static string Grouped(int value) => value.ToString("N0", CultureInfo.InvariantCulture);
  public static string ViewerMeta(int? lines, FileRead? read) => lines is { } count && read is { Kind: FileReadKind.Text } ? $"{Grouped(count)} lines · {FormatBytes(read.Bytes)}" : "";
  public static string TooLargeLine(long bytes, long limit) => $"This file is {FormatBytes(bytes)}, over the {FormatBytes(limit)} viewer limit. Open it in your editor instead.";
  public static string BinaryLine(long bytes) => $"Binary file — {FormatBytes(bytes)}. Nothing readable to show.";
  public static string ErrorLine(string message) => "Could not open this file — " + message;
  public static string ShownLine(int shown, int count) => $"Showing the first {Grouped(shown)} of {Grouped(count)} lines. Open it in your editor to see the rest.";
  public static (string Source, int Count, int Shown) Document(string text)
  {
    var trimmed = text.EndsWith('\n') ? text[..^1] : text;
    var count = 1; int? cut = null;
    for (var i = 0; i < trimmed.Length; i++)
      if (trimmed[i] == '\n') { count++; if (count == MaxViewLines + 1) cut = i; }
    return (cut is { } at ? trimmed[..at] : trimmed, count, Math.Min(count, MaxViewLines));
  }
  public static string Gutter(int count) => string.Join("\n", Enumerable.Range(1, Math.Max(1, count)));
  public static bool LooksBinary(ReadOnlySpan<byte> bytes)
  {
    var probe = bytes[..Math.Min(bytes.Length, 8000)];
    return probe.IndexOf((byte)0) >= 0;
  }
}

// Reads one project folder for the Files page and the files.* tools. Every
// path stays inside the folder; a link that leaves it, or loops, is shown but
// never followed.
public sealed class ProjectFiles(ICodeProcessRunner? runner = null)
{
  private readonly ICodeProcessRunner process = runner ?? new CodeProcessRunner();
  private static readonly string[] Readmes = ["README.md", "README", "readme.md", "README.txt"];
  public static readonly HashSet<string> NeverWalk = new(StringComparer.OrdinalIgnoreCase) { ".git" };

  public static string RequireRoot(string root)
  {
    if (string.IsNullOrWhiteSpace(root)) throw new ArgumentException("Choose a project folder first.");
    var full = Path.GetFullPath(root);
    if (!Directory.Exists(full)) throw new DirectoryNotFoundException("That folder is gone.");
    return Path.TrimEndingDirectorySeparator(full);
  }
  public static string Resolve(string root, string relPath)
  {
    root = RequireRoot(root);
    relPath = (relPath ?? "").Replace('\\', '/').Trim('/');
    if (relPath.Split('/').Any(part => part is ".." ) || Path.IsPathRooted(relPath)) throw new ArgumentException("That path is outside this project.");
    var full = Path.GetFullPath(Path.Combine(root, relPath.Replace('/', Path.DirectorySeparatorChar)));
    if (!Inside(root, full)) throw new ArgumentException("That path is outside this project.");
    return full;
  }
  public static bool Inside(string root, string full)
  {
    var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    root = Path.TrimEndingDirectorySeparator(root);
    return string.Equals(full, root, comparison) || full.StartsWith(root + Path.DirectorySeparatorChar, comparison);
  }
  public static string Relative(string root, string full)
  {
    var rel = Path.GetRelativePath(root, full).Replace('\\', '/');
    return rel == "." ? "" : rel;
  }

  private static bool Blocked(string root, FileSystemInfo info)
  {
    if (info.LinkTarget is null) return false;
    try
    {
      var target = info.ResolveLinkTarget(returnFinalTarget: true);
      return target is null || !target.Exists || !Inside(root, Path.GetFullPath(target.FullName));
    }
    catch (IOException) { return true; }
    catch (UnauthorizedAccessException) { return true; }
  }

  public async Task<DirListing> ListAsync(string root, string relPath, bool showIgnored, CancellationToken ct = default)
  {
    root = RequireRoot(root);
    var folder = Resolve(root, relPath);
    var info = new DirectoryInfo(folder);
    if (!info.Exists) throw new DirectoryNotFoundException("That folder is gone.");
    if (relPath.Length > 0 && Blocked(root, info)) throw new UnauthorizedAccessException("This link leaves the project, or loops.");
    var options = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false, AttributesToSkip = FileAttributes.System };
    var entries = new List<FsEntry>(); var truncated = false;
    foreach (var item in info.EnumerateFileSystemInfos("*", options))
    {
      ct.ThrowIfCancellationRequested();
      if (NeverWalk.Contains(item.Name)) continue;
      if (entries.Count >= FilesRules.MaxEntries) { truncated = true; break; }
      var rel = Relative(root, item.FullName);
      var dir = item is DirectoryInfo;
      entries.Add(new(item.Name, rel, dir, item.LinkTarget is not null, Blocked(root, item)));
    }
    // A linked folder is asked about as a plain name: git refuses paths "beyond a symbolic link".
    static string Probe(FsEntry e) => e.IsDir && !e.Symlink ? e.RelPath + "/" : e.RelPath;
    var ignored = await IgnoredAsync(root, entries.Select(Probe).ToArray(), ct);
    var rows = entries.Select(e => e with { Ignored = ignored.Contains(Probe(e)) })
      .Where(e => showIgnored || !e.Ignored)
      .OrderByDescending(e => e.IsDir).ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    var readme = relPath.Length == 0 ? Readmes.FirstOrDefault(r => rows.Any(e => !e.IsDir && e.Name == r)) : null;
    return new(relPath, rows, truncated, readme);
  }

  // `git check-ignore` is the one source of truth for .gitignore; outside a
  // repository nothing is ignored.
  public async Task<HashSet<string>> IgnoredAsync(string root, IReadOnlyList<string> relPaths, CancellationToken ct = default)
  {
    var result = new HashSet<string>(StringComparer.Ordinal);
    if (relPaths.Count == 0) return result;
    var answer = await process.RunAsync("git", ["-C", root, "check-ignore", "--stdin", "-z"], root, TimeSpan.FromSeconds(10), ct, string.Join('\0', relPaths) + "\0");
    if (answer.Missing || answer.TimedOut || answer.ExitCode > 1) return result;
    foreach (var path in answer.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries)) result.Add(path.Replace('\\', '/'));
    return result;
  }

  public async Task<FileRead> ReadAsync(string root, string relPath, CancellationToken ct = default)
  {
    var full = Resolve(root, relPath);
    var info = new FileInfo(full);
    if (!info.Exists) throw new FileNotFoundException("That file is gone.");
    if (Blocked(RequireRoot(root), info)) throw new UnauthorizedAccessException("This link leaves the project, or loops.");
    var rel = Relative(RequireRoot(root), full);
    if (info.Length > FilesRules.MaxReadBytes) return new(rel, FileReadKind.TooLarge, (int)Math.Min(info.Length, int.MaxValue), Limit: FilesRules.MaxReadBytes);
    var bytes = await File.ReadAllBytesAsync(full, ct);
    if (FilesRules.LooksBinary(bytes)) return new(rel, FileReadKind.Binary, bytes.Length);
    return new(rel, FileReadKind.Text, bytes.Length, new UTF8Encoding(false, false).GetString(bytes).TrimStart('﻿'));
  }

  // Name search across the folder: ignored files and links that leave the project are skipped.
  public async Task<IReadOnlyList<FileMatch>> SearchAsync(string root, string query, bool showIgnored, CancellationToken ct = default)
  {
    root = RequireRoot(root); query = (query ?? "").Trim();
    if (query.Length == 0) return [];
    var options = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false, AttributesToSkip = FileAttributes.System | FileAttributes.ReparsePoint };
    var pending = new Queue<string>(); pending.Enqueue(root); var found = new List<FileMatch>(); var visited = 0;
    while (pending.TryDequeue(out var directory) && visited < 50_000 && found.Count < FilesRules.MaxSearchResults)
    {
      ct.ThrowIfCancellationRequested();
      var children = new List<(string Rel, bool Dir, string Full)>();
      foreach (var item in new DirectoryInfo(directory).EnumerateFileSystemInfos("*", options))
      {
        if (NeverWalk.Contains(item.Name)) continue;
        visited++; children.Add((Relative(root, item.FullName), item is DirectoryInfo, item.FullName));
      }
      var ignored = showIgnored ? [] : await IgnoredAsync(root, children.Select(c => c.Dir ? c.Rel + "/" : c.Rel).ToArray(), ct);
      foreach (var child in children)
      {
        if (ignored.Contains(child.Dir ? child.Rel + "/" : child.Rel)) continue;
        if (child.Dir) pending.Enqueue(child.Full);
        else if (child.Rel.Contains(query, StringComparison.OrdinalIgnoreCase)) { found.Add(new(child.Rel, FilesRules.Name(child.Rel))); if (found.Count >= FilesRules.MaxSearchResults) break; }
      }
    }
    return found.OrderBy(f => f.Name.StartsWith(query, StringComparison.OrdinalIgnoreCase) ? 0 : 1).ThenBy(f => f.RelPath.Length).ToArray();
  }
}
