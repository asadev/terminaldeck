using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

/// FOLDERS THAT TRAVEL WITH THE PROJECT (Asad, 19 Nov 2026: "the Commands and all this stuff should travel to all the
/// team notes, tools, logs, and other things also. Everything should be same ... So everything should travel. including
/// actually pictures and everything don't worry about cloud limits."). The Mac's CloudProjectFoldersRules
/// (lane/setup-travels CloudProjectFolders.swift), written here to the same rules so records are the same everywhere.
///
/// Every top-level folder of every project on this PC travels to every device of the account, all kinds of files, with no
/// size or day cap of ours. Left out only what is rebuilt or comes from git (code checkouts, `.git`, build outputs and
/// caches, installers, package folders, the .NET SDK), the system's own scratch files and links. Carried by the Cloud
/// folder's owner (CloudFolderOwner, kind CloudFileKind.ProjectFolders, row I26) over many roots (CloudFolderRoots): a
/// record's path is `<project key>/<folder>/<path in it>`; the key is made from the project's id, so every device places
/// it in ITS folder of that project.
public static class CloudProjectFoldersRules
{
  public const string InventoryRow = "I26";
  public const string Domain = "project-folders";
  /// "Every device understands project-folder records" (the account's announce); no dot allowed.
  public const string Feature = "projectfolders";
  public const int Format = 1;

  /// An override (optional): one folder name per line in this file of the project (it travels with the project's
  /// instruction files). Absent: every top-level folder.
  public const string ListFile = ".terminaldeck/travel-folders";
  /// What is rebuilt or comes from git: never travels, at any depth.
  public static readonly IReadOnlySet<string> NeverFolders = new HashSet<string>(CloudFolderRules.RebuildableFolders.Concat(
    ["code", ".git", "build", "build-cache", "installers", "dist", ".next", ".turbo", ".cache", "dotnet", "dotnet-nuget", ".nuget", ".swiftpm", ".wrangler", "xcuserdata"]),
    StringComparer.Ordinal);
  /// The system's own scratch files and half-written downloads.
  public static readonly IReadOnlySet<string> JunkNames = new HashSet<string>(StringComparer.Ordinal)
    { ".ds_store", ".localized", "icon\r", "thumbs.db", "desktop.ini", ".spotlight-v100", ".trashes", ".fseventsd" };
  public static readonly string[] JunkPrefixes = ["._", ".~lock", "~$", ".td-cloud-", ".terminaldeck-stage-"];
  public static readonly string[] JunkEndings = [".swp", ".swo", ".swx", ".crdownload", ".download", ".part", ".partial", ".icloud"];

  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Every folder of your projects travels, with every kind of file.",
    "Left out: code checkouts, build outputs and caches, installers and package folders (they are made again on each device), links, and the system's own scratch files."
  ];

  /// The key of a project in a record's path: "p" and 16 hex of the project's id. The same on every device.
  public static string Key(string projectId) =>
    "p" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("td-project-folders\n" + projectId)))[..16];
  public static bool IsKey(string text) => text.Length == 17 && text[0] == 'p' && text[1..].All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
  public static bool Junk(string lowerName) =>
    JunkNames.Contains(lowerName) || JunkPrefixes.Any(p => lowerName.StartsWith(p, StringComparison.Ordinal)) || JunkEndings.Any(e => lowerName.EndsWith(e, StringComparison.Ordinal));

  /// The top-level folders of this project that travel: every real folder (no link, not hidden, not on the never list),
  /// or the names in the override file. A folder that is a code checkout (it holds `.git`) never travels.
  public static IReadOnlyList<string> Folders(string projectRoot)
  {
    IEnumerable<string> names;
    var list = Path.Combine(projectRoot, ".terminaldeck", "travel-folders");
    string? text = null;
    try { if (RegularFile(list)) text = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(list)); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or DecoderFallbackException) { text = null; }
    if (text is not null)
      names = text.Split(['\n', '\r', '\u000b', '\u000c', '\u0085', '\u2028', '\u2029']).Select(l => l.Trim(' ', '\t')).Where(l => l.Length > 0 && !l.StartsWith('#'));
    else
    {
      try { names = new DirectoryInfo(projectRoot).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = true })
        .Select(i => i.Name).Order(StringComparer.Ordinal).ToArray(); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { names = []; }
    }
    var output = new List<string>();
    foreach (var name in names)
    {
      if (name.Contains('/') || name.Contains('\\') || name.StartsWith('.') || NeverFolders.Contains(name.ToLowerInvariant()) || output.Contains(name)) continue;
      var path = Path.Combine(projectRoot, name);
      if (!RealFolder(path) || IsCheckout(path)) continue;
      output.Add(name);
    }
    return output;
  }
  private static FileAttributes? Attributes(string path)
  {
    try { return File.GetAttributes(path); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
  public static bool RealFolder(string path) => Attributes(path) is { } a && (a & FileAttributes.Directory) != 0 && (a & FileAttributes.ReparsePoint) == 0;
  private static bool RegularFile(string path) => Attributes(path) is { } a && (a & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
  /// A folder with `.git` in it (a folder, or the file of a worktree) is a code checkout.
  public static bool IsCheckout(string folder) => Attributes(Path.Combine(folder, ".git")) is not null;

  /// Null when the file at `relative` (`<key>/<folder>/<path>`) travels. Asked on the sending device and on arrival.
  public static CloudFolderSkip? Refusal(string relative)
  {
    if (!CloudBootFilesFormat.CleanRelative(relative) || CloudBootFilesFormat.Parts(relative) is not { } parts || parts.Length < 3
      || parts.Length > CloudFolderFormat.MaximumDepth + 2 || !IsKey(parts[0])) return CloudFolderSkip.Name;
    if (parts[1].StartsWith('.')) return CloudFolderSkip.Hidden;
    for (var i = 1; i < parts.Length - 1; i++) if (NeverFolders.Contains(parts[i].ToLowerInvariant())) return CloudFolderSkip.Rebuildable;
    if (Junk(parts[^1].ToLowerInvariant())) return CloudFolderSkip.Temporary;
    return null;
  }

  /// Every project of this PC whose one folder is real and inside the home folder (never the home itself), by its key.
  /// The same project id gives the same key on every device.
  public static Dictionary<string, string> Roots(IReadOnlyDictionary<string, string> projectFolders, string home)
  {
    var roots = new Dictionary<string, string>(StringComparer.Ordinal);
    string homePath;
    try { homePath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(home)); }
    catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return roots; }
    foreach (var (projectId, folder) in projectFolders)
    {
      string root;
      try
      {
        if (string.IsNullOrEmpty(folder) || !Path.IsPathFullyQualified(folder)) continue;
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
      }
      catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { continue; }
      if (!root.StartsWith(homePath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !RealFolder(root)) continue;
      roots[Key(projectId)] = root;
    }
    return roots;
  }
}

/// Where an owner's paths live on this PC. One folder (the Cloud folder: a path is relative to it), or many (project
/// folders: the first part of a path is a project key, the rest is relative to that project's folder). The many-roots map
/// changes when projects are added or moved; the owner reads it at every step.
public sealed class CloudFolderRoots
{
  private readonly object gate = new();
  private Dictionary<string, string> many = new(StringComparer.Ordinal);
  public string? Single { get; }
  public CloudFolderRoots(string single) => Single = single;
  public CloudFolderRoots(IReadOnlyDictionary<string, string> many) => this.many = new(many, StringComparer.Ordinal);
  public bool IsMany => Single is null;
  public void Set(IReadOnlyDictionary<string, string> next) { lock (gate) many = new(next, StringComparer.Ordinal); }
  public IReadOnlyDictionary<string, string> All { get { lock (gate) return many; } }
  public bool Same(IReadOnlyDictionary<string, string> other)
  {
    var now = All;
    return now.Count == other.Count && now.All(p => other.TryGetValue(p.Key, out var o) && string.Equals(o, p.Value, StringComparison.OrdinalIgnoreCase));
  }

  /// The folder and the path inside it. Null: a project not on this PC (its files wait in the private copy).
  public (string Root, string Relative)? Locate(string path)
  {
    if (Single is { } single) return (single, path);
    var slash = path.IndexOf('/');
    if (slash <= 0) return null;
    string? root;
    lock (gate) root = many.GetValueOrDefault(path[..slash]);
    var rest = path[(slash + 1)..];
    return root is null || rest.Length == 0 ? null : (root, rest);
  }

  public bool CaseClash(string path) => Locate(path) is { } p && CloudFolderDisk.CaseClash(p.Root, p.Relative);
  public bool FileFolderClash(string path) => Locate(path) is { } p && CloudFolderDisk.FileFolderClash(p.Root, p.Relative);
  public CloudFolderDisk.Stamp? StampOf(string path) => Locate(path) is { } p ? CloudFolderDisk.StampOf(p.Root, p.Relative) : null;
  public CloudFolderDisk.Found Read(string path) => Locate(path) is { } p ? CloudFolderDisk.Read(p.Root, p.Relative) : CloudFolderDisk.Found.Blocked;
  public long? Modified(string path) => Locate(path) is { } p ? CloudFolderDisk.Modified(p.Root, p.Relative) : null;
  public void SetModified(string path, long at) { if (Locate(path) is { } p) CloudFolderDisk.SetModified(p.Root, p.Relative, at); }
  public void Write(string path, byte[] bytes, string? expecting)
  {
    var p = Locate(path) ?? throw new CloudFailure("unavailable");
    CloudFolderDisk.Write(p.Root, p.Relative, bytes, expecting);
  }
  public void Remove(string path, string expecting)
  {
    var p = Locate(path) ?? throw new CloudFailure("unavailable");
    CloudFolderDisk.Remove(p.Root, p.Relative, expecting);
  }
  /// The file's own place on disk, or null for a project not on this PC.
  public string? Full(string path) => Locate(path) is { } p ? CloudFolderDisk.Full(p.Root, p.Relative) : null;

  /// One look over every root. One folder: as before. Many: each project's travelling folders, paths under its key.
  public CloudFolderWalk Walk(CloudFileKind kind)
  {
    if (Single is { } single) return CloudFolderWalk.Run(single, kind);
    var walk = new CloudFolderWalk();
    foreach (var (key, root) in All.OrderBy(p => p.Key, StringComparer.Ordinal))
    {
      if (!CloudProjectFoldersRules.RealFolder(root)) continue;
      foreach (var name in CloudProjectFoldersRules.Folders(root))
      {
        walk.Merge(CloudFolderWalk.Run(Path.Combine(root, name), kind, key + "/" + name + "/"));
        if (walk.Files.Count > kind.MaximumFiles) { walk.MarkUnreliable(); return walk; }
      }
    }
    return walk;
  }
}
