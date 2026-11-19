using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Lane F (15 Nov): the Cloud folder's numbers, words and path rules, and the delete rule's bookkeeping of the file
// engines, ported one to one from the Mac (td-mac-next2 BackendCloudFolderRules.swift). Every number is the Mac's;
// Windows wording says "PC" where the Mac says "Mac".

public static class CloudFolderFormat
{
  public const string InventoryRow = "I24";
  public const string FolderName = "Terminal Deck Cloud";
  public static string Domain => DomainOf(InventoryRow);
  /// CloudBrainFilesFormat.ownDomainRows: I23 artifacts, I24 the Cloud folder (each a domain of its own).
  public static string DomainOf(string row) => row switch
  {
    "I24" => "cloud-folder", "I23" => "artifacts", CloudProjectFoldersRules.InventoryRow => CloudProjectFoldersRules.Domain, _ => throw new CloudFailure("invalid_request")
  };
  /// `%USERPROFILE%\Terminal Deck Cloud`.
  public static string DefaultFolder(string? home = null) => Path.Combine(home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), FolderName);
  public const long MaximumFileBytes = 25_000_000;
  public const long MaximumFolderBytes = 1_000_000_000;
  public const long DailySendBytes = 200_000_000;
  public const int VersionsPerDay = 6;
  public const long StillAfterLimit = 3_600_000;
  public const long RoomFloor = 3_000_000_000;
  public const long DiskFloor = 2_000_000_000;
  public const long SafetyKeptFor = 30L * 86_400_000;
  public const long Day = 86_400_000;
  public const int MaximumFiles = 20_000;
  public const int MaximumDepth = 32;
  public const long Quiet = 3_000;
  public const long BusyGap = 60_000;
  public const long BusyLongGap = 600_000;
  public const int BusyStreak = 3;
  public const string Feature = "cloudfolder";
  public const int Format = 1;

  public static string TooLargeLine(int count) => count == 1
    ? "1 file larger than 25 MB stays on this PC (the Cloud folder carries files up to 25 MB)."
    : count.ToString(CultureInfo.InvariantCulture) + " files larger than 25 MB stay on this PC (the Cloud folder carries files up to 25 MB).";
  /// Every AI session is told where his Cloud folder is (only when it exists on this PC).
  public static string SessionLine(string? folder = null)
  {
    var at = folder ?? DefaultFolder();
    if (!Directory.Exists(at)) return "";
    return "\n\nThe person's Cloud folder is " + at + ": whatever is in it is on all their devices. Read and write files there " +
      "directly when they ask for something to be on all their devices (files up to 25 MB travel; hidden files, links, package folders " +
      "and key or sign-in files stay on this PC). Never delete files there unless the person asked.";
  }
  public const string FolderFullLine = "Your Cloud folder holds more than 1 GB. New and changed files stay on this PC until it is smaller.";
  public const string DayFullLine = "Your Cloud folder and artifacts sent 200 MB from this PC today, the most for one day. Changed files wait until tomorrow.";
  public static string BusyLine(int count) => count == 1
    ? "1 file in your Cloud folder changed more than 6 times today. It is sent once it has been still for an hour."
    : count.ToString(CultureInfo.InvariantCulture) + " files in your Cloud folder changed more than 6 times today. Each is sent once it has been still for an hour.";
  public const string RoomLowLine = "Your Cloud account has less than 3 GB of room left, so your Cloud folder sends nothing more. Memory and everything else keep travelling.";
  public const string DiskLowLine = "This PC has less than 2 GB free, so files from your other devices wait until there is more room.";
  /// Names said on the page: at most three, then "and N more".
  public static string Names(IEnumerable<string> list)
  {
    var sorted = list.Distinct().OrderBy(n => n, StringComparer.Ordinal).ToArray();
    var shown = string.Join(", ", sorted.Take(3));
    return sorted.Length > 3 ? shown + " and " + (sorted.Length - 3).ToString(CultureInfo.InvariantCulture) + " more" : shown;
  }
  /// BackendCloudContentsWords.list: "A", "A and B", "A, B and C".
  public static string List(IReadOnlyList<string> parts) => parts.Count switch
  {
    0 => "", 1 => parts[0], 2 => parts[0] + " and " + parts[1],
    _ => string.Join(", ", parts.Take(parts.Count - 1)) + " and " + parts[^1]
  };
  private static string Count(IReadOnlyList<string> names, string one, string many) =>
    (names.Count == 1 ? one : names.Count.ToString(CultureInfo.InvariantCulture) + many) + Names(names);
  public static string SecretLine(IReadOnlyList<string> names) =>
    Count(names, "1 file stays on this PC because its name is on the never-send list for keys, environment and sign-in files: ",
      " files stay on this PC because their names are on the never-send list for keys, environment and sign-in files: ") + ".";
  public static string SpellingLine(IReadOnlyList<string> names) =>
    Count(names, "1 file stays on this PC because its name is spelled with separate accent marks: ",
      " files stay on this PC because their names are spelled with separate accent marks: ") + ". Renaming it lets it travel.";
  public static string ClashLine(IReadOnlyList<string> names) =>
    Count(names, "1 file stays apart because its name is a file on one device and a folder on another: ",
      " files stay apart because their names are a file on one device and a folder on another: ") + ".";
  public static string GateLine(IReadOnlyList<string> devices)
  {
    var sorted = devices.Distinct().OrderBy(n => n, StringComparer.Ordinal).ToArray();
    return "Your Cloud folder sends nothing yet: " + List(sorted) + (devices.Count == 1 ? " has" : " have") + " not updated Terminal Deck or "
      + (devices.Count == 1 ? "has" : "have") + " Cloud off.";
  }
  /// "plan (from MacBook Pro).md", then "plan (from MacBook Pro) 2.md".
  public static string BesideName(string name, string device, int number)
  {
    var dot = name.LastIndexOf('.');
    string stem = dot > 0 ? name[..dot] : name, ext = dot > 0 ? name[(dot + 1)..] : "";
    var safe = device.Replace("/", "-", StringComparison.Ordinal).Replace(":", "-", StringComparison.Ordinal).Replace("\\", "-", StringComparison.Ordinal);
    return stem + " (from " + safe + ")" + (number > 1 ? " " + number.ToString(CultureInfo.InvariantCulture) : "") + (ext.Length == 0 ? "" : "." + ext);
  }
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Hidden files, temporary files and links stay on this PC.",
    "Keys, environment files and sign-in files never travel.",
    "Folders of installed packages and build output (node_modules, .build, DerivedData) stay on this PC."
  ];
}

/// What never leaves this PC from the Cloud folder, and why. Asked again for every path, in both directions.
public enum CloudFolderSkip { Hidden, Temporary, Link, Rebuildable, Secret, TooLarge, Name, NotAFile }

public static class CloudFolderRules
{
  public static readonly IReadOnlySet<string> RebuildableFolders = new HashSet<string> { "node_modules", ".build", "deriveddata", "__pycache__", "venv", ".venv", "pods", ".gradle" };
  private static readonly string[] TemporaryEndings = ["~", ".tmp", ".temp", ".swp", ".swo", ".swx", ".part", ".partial", ".crdownload", ".download", ".icloud"];
  private static readonly string[] TemporaryPrefixes = ["~$", ".~lock", "._", ".td-cloud-"];

  /// The app's own never-send list (the instruction files' list: keys, environment and sign-in files, by name).
  public static bool IsSecret(string name)
  {
    var lower = name.ToLowerInvariant();
    return CloudBootFilesFormat.NeverFileNames.Contains(lower) || CloudBootFilesFormat.NeverFileEndings.Any(e => lower.EndsWith(e, StringComparison.Ordinal))
      || CloudBootFilesFormat.NeverNameParts.Any(p => lower.Contains(p, StringComparison.Ordinal)) || CloudBootFilesFormat.NeverNamePrefixes.Any(p => lower.StartsWith(p, StringComparison.Ordinal));
  }

  /// null when the file at `relative` (inside the folder) may travel. Sizes are checked by the walk.
  public static CloudFolderSkip? Refusal(string relative)
  {
    if (!CloudBootFilesFormat.CleanRelative(relative) || CloudBootFilesFormat.Parts(relative) is not { } parts || parts.Length > CloudFolderFormat.MaximumDepth) return CloudFolderSkip.Name;
    for (var index = 0; index < parts.Length; index++)
    {
      var name = parts[index];
      var lower = name.ToLowerInvariant();
      var last = index == parts.Length - 1;
      if (!last && RebuildableFolders.Contains(lower)) return CloudFolderSkip.Rebuildable;
      if (TemporaryPrefixes.Any(p => lower.StartsWith(p, StringComparison.Ordinal))) return CloudFolderSkip.Temporary;
      if (name.StartsWith('.')) return CloudFolderSkip.Hidden;
      if (last)
      {
        if (TemporaryEndings.Any(e => lower.EndsWith(e, StringComparison.Ordinal))) return CloudFolderSkip.Temporary;
        if (IsSecret(lower)) return CloudFolderSkip.Secret;
      }
    }
    return null;
  }

  /// Explorer's own files (`Thumbs.db`, `desktop.ini`, any letter case): this PC never sends them.
  public static bool IsExplorerOwn(string name) =>
    string.Equals(name, "Thumbs.db", StringComparison.OrdinalIgnoreCase) || string.Equals(name, "desktop.ini", StringComparison.OrdinalIgnoreCase);

  /// Windows only (plan section 4, the smallest equivalent): a name another device can make that Windows cannot hold
  /// (`<>:"|?*`, a name ending in a dot or space, a device name such as CON or NUL). Such an arrival is kept unread and
  /// never written here, as a refused path is on the Mac; nothing of this PC is touched.
  public static bool WindowsCannotHold(string relative)
  {
    foreach (var name in relative.Split('/'))
    {
      if (name.Length == 0 || name.EndsWith('.') || name.EndsWith(' ') || name.IndexOfAny(['<', '>', ':', '"', '|', '?', '*']) >= 0) return true;
      var stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
      if (stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$") return true;
      if (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] is >= '0' and <= '9' or '¹' or '²' or '³') return true;
    }
    return false;
  }
}

/// One look at a folder: every file that may travel with its size and time, never following a link, and what was left
/// out by reason. `Reliable` false = something could not be read: no removal is ever inferred from such a look.
/// `Present` false = the folder itself is not there: nothing is inferred.
public sealed class CloudFolderWalk
{
  public sealed record Entry(long Bytes, long Modified);
  public Dictionary<string, Entry> Files { get; } = new(StringComparer.Ordinal);
  public Dictionary<CloudFolderSkip, int> Skipped { get; } = [];
  public List<string> SecretNames { get; } = [];
  public List<string> SpellingNames { get; } = [];
  /// Paths that exist on disk but do not travel (their absence from `Files` is never a removal).
  public HashSet<string> ExcludedPaths { get; } = new(StringComparer.Ordinal);
  public long Bytes { get; private set; }
  public bool Present { get; private set; } = true;
  public bool Reliable { get; private set; } = true;

  private void Skip(CloudFolderSkip why, string relative) { Skipped[why] = Skipped.GetValueOrDefault(why) + 1; ExcludedPaths.Add(relative); }
  internal void MarkUnreliable() => Reliable = false;
  /// Another root's look added to this one (project folders: one walk per project folder).
  internal void Merge(CloudFolderWalk other)
  {
    foreach (var (path, entry) in other.Files) Files.TryAdd(path, entry);
    foreach (var (why, count) in other.Skipped) Skipped[why] = Skipped.GetValueOrDefault(why) + count;
    SecretNames.AddRange(other.SecretNames); SpellingNames.AddRange(other.SpellingNames);
    ExcludedPaths.UnionWith(other.ExcludedPaths);
    Bytes += other.Bytes;
    if (!other.Present || !other.Reliable) Reliable = false;
  }

  public static CloudFolderWalk Run(string root) => Run(root, CloudFileKind.CloudFolder);
  /// `kind` gives the rules (path rule, size, count); `under` is put before every path (a project folder's key/name/).
  public static CloudFolderWalk Run(string root, CloudFileKind kind, string under = "")
  {
    var walk = new CloudFolderWalk();
    var projects = kind.PathRule is not null;
    if (!CloudFolderDisk.IsPlainFolder(root)) { walk.Present = false; walk.Reliable = false; return walk; }
    var pending = new Stack<(string Full, string Relative)>();
    pending.Push((root, under.TrimEnd('/')));
    while (pending.Count > 0)
    {
      var (folder, prefix) = pending.Pop();
      IEnumerable<FileSystemInfo> children;
      try { children = new DirectoryInfo(folder).EnumerateFileSystemInfos().ToArray(); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { walk.Reliable = false; continue; }
      foreach (var child in children)
      {
        var relative = prefix.Length == 0 ? child.Name : prefix + "/" + child.Name;
        FileAttributes attributes;
        try { attributes = child.Attributes; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { walk.Reliable = false; continue; }
        if ((attributes & FileAttributes.ReparsePoint) != 0) { walk.Skip(CloudFolderSkip.Link, relative); continue; }
        if ((attributes & FileAttributes.Directory) != 0)
        {
          var lower = child.Name.ToLowerInvariant();
          if (projects)
          {
            // Project folders: only what is rebuilt or comes from git stays; hidden folders travel too.
            if (CloudProjectFoldersRules.NeverFolders.Contains(lower) || CloudProjectFoldersRules.IsCheckout(child.FullName)) walk.Skip(CloudFolderSkip.Rebuildable, relative);
            else pending.Push((child.FullName, relative));
            continue;
          }
          if (CloudFolderRules.RebuildableFolders.Contains(lower)) { walk.Skip(CloudFolderSkip.Rebuildable, relative); continue; }
          if (lower.StartsWith('.')) { walk.Skip(CloudFolderSkip.Hidden, relative); continue; }
          pending.Push((child.FullName, relative));
          continue;
        }
        if (child is not FileInfo file) { walk.Skip(CloudFolderSkip.NotAFile, relative); continue; }
        // Windows (Decker, 15 Nov): Explorer's own files are never sent from this PC. One that arrived is kept as any file.
        // (Project folders leave them out by their own rule, as the system's scratch.)
        if (!projects && CloudFolderRules.IsExplorerOwn(child.Name)) { walk.Skip(CloudFolderSkip.Hidden, relative); continue; }
        if (kind.Refusal(relative) is { } why)
        {
          walk.Skip(why, relative);
          if (why == CloudFolderSkip.Secret) walk.SecretNames.Add(child.Name);
          if (why == CloudFolderSkip.Name && !string.Equals(relative, relative.Normalize(NormalizationForm.FormC), StringComparison.Ordinal))
            walk.SpellingNames.Add(child.Name.Normalize(NormalizationForm.FormC));
          continue;
        }
        long size, modified;
        try { size = file.Length; modified = CloudFolderDisk.Ms(file.LastWriteTimeUtc); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { walk.Reliable = false; continue; }
        if (size > kind.MaximumFileBytes) { walk.Skip(CloudFolderSkip.TooLarge, relative); continue; }
        walk.Files[relative] = new Entry(size, modified);
        walk.Bytes += size;
        if (walk.Files.Count > kind.MaximumFiles) { walk.Reliable = false; return walk; }
      }
    }
    return walk;
  }
}

public static class CloudFolderWords
{
  public static string? WaitingAnswer(CloudFolderAnswer answer) => answer.FolderMissing ? "Your Cloud folder is not on this PC" : null;
  public const string MakeItAgain = "Make it again";
}

/// Only the root's absence is reported. Individual missing files are persistent local marks, never questions.
public sealed record CloudFolderAnswer(bool FolderMissing);

/// One file in a file kind's Bin on this PC (30 days), or one of its earlier versions. Names and dates only on screen.
public sealed record CloudFolderKept(string Path, string Name, string? Place, long At, string Device, long Bytes, long KeptUntil, string Sha256);

/// "<device>'s newer <file> is in use; this PC's version is kept until <date>", one per replaced file.
public sealed record CloudFolderReplacedLine(string Device, string Name, string? Place, long KeptUntil, string ItemId);

/// The delete rule's bookkeeping of one file owner (the Mac's `file_delete_*` tables, BackendCloudFolderRules.swift
/// `CloudFileDeleteRecords`), kept inside the owner's one state file. Never sent.
public sealed class CloudFileDeleteBook
{
  public sealed class AboutRow { public string Body { get; set; } = ""; public string Signer { get; set; } = ""; }
  public sealed class HeadRow
  {
    public string Place { get; set; } = ""; public string Version { get; set; } = ""; public List<string> Parents { get; set; } = []; public long At { get; set; }
    public string Mac { get; set; } = ""; public Dictionary<string, string> Fields { get; set; } = [];
  }
  public sealed class SendingRow
  {
    public string Scope { get; set; } = ""; public string By { get; set; } = ""; public string Mac { get; set; } = ""; public string? Session { get; set; }
    public string? Agent { get; set; } public long At { get; set; } public string Group { get; set; } = ""; public long AfterSeq { get; set; }
  }
  public sealed class WithdrawnRow { public string Place { get; set; } = ""; public List<string> Parents { get; set; } = []; public bool Done { get; set; } }
  public sealed class RowError { public string Line { get; set; } = ""; public long At { get; set; } }
  public sealed class UndoRow { public string Scope { get; set; } = ""; public bool Restore { get; set; } }
  public sealed class GroupRow
  {
    public string Id { get; set; } = ""; public string By { get; set; } = ""; public string MacName { get; set; } = ""; public string? Session { get; set; }
    public string? Agent { get; set; } public long At { get; set; } public string Era { get; set; } = "current";
    public List<string[]> Items { get; set; } = [];
  }

  public Dictionary<string, AboutRow> About { get; set; } = [];
  public HashSet<string> Refused { get; set; } = [];
  public Dictionary<string, HeadRow> Heads { get; set; } = [];
  public Dictionary<string, GroupRow> Bin { get; set; } = [];
  public Dictionary<string, string> Binned { get; set; } = [];
  public HashSet<string> Applying { get; set; } = [];
  public Dictionary<string, SendingRow> Sending { get; set; } = [];
  public Dictionary<string, WithdrawnRow> Withdrawn { get; set; } = [];
  public Dictionary<string, RowError> RowErrors { get; set; } = [];
  public HashSet<string> Cleared { get; set; } = [];
  public Dictionary<string, UndoRow> Undo { get; set; } = [];

  public static GroupRow Store(CloudBinGroup g) => new()
  {
    Id = g.Id, By = CloudDeleteText.Raw(g.By), MacName = g.MacName, Session = g.Session, Agent = g.Agent, At = g.At, Era = CloudFileDeleteRecords.EraRaw(g.Era),
    Items = g.Items.Select(i => new[] { i.Id, i.Kind, i.Name, i.Place ?? "" }).ToList()
  };
  public static CloudBinGroup Group(GroupRow g) => new(g.Id, CloudDeleteText.By(g.By) ?? CloudDeleteBy.Person, g.MacName, g.Session, g.Agent, g.At,
    g.Items.Select(i => new CloudDeleteItem(i[0], i[1], i[2], i[3].Length == 0 ? null : i[3])).ToArray(),
    g.Era switch { "olderVersion" => CloudBinEra.OlderVersion, "beforeNewRule" => CloudBinEra.BeforeNewRule, _ => CloudBinEra.Current });

  public static string AboutJson(CloudFileDeleteRecords.About about) => Encoding.UTF8.GetString(CloudCanonical.Encode(about.ToJson()));
  public static CloudFileDeleteRecords.About? AboutOf(string body)
  {
    try { return CloudFileDeleteRecords.About.FromJson(CloudJson.Parse(body)); }
    catch (Exception e) when (e is CloudDeleteRuleException or CloudFailure or FormatException or JsonException) { return null; }
  }

  // ---- The sender's and receiver's steps (CloudFileDeleteRecords on the Mac) ----

  /// An about-record of an arriving pack, saved with the VERIFIED signer before its removal is read. A forged or
  /// different one is refused (`invalid_request`: that one record is passed over; its removal is then applied safely).
  public void SaveAbout(CloudOperation operation, string signer)
  {
    if (CloudFileDeleteRecords.Read(operation) is not { } about) { Refused.Add(operation.OpId); throw new CloudFailure("invalid_request"); }
    if (!string.Equals(about.Mac, signer, StringComparison.OrdinalIgnoreCase)) { Refused.Add(operation.OpId); throw new CloudFailure("invalid_request"); }
    if (About.TryGetValue(about.Operation, out var old) && (AboutOf(old.Body) is not { } held || !held.Same(about)))
    {
      Refused.Add(operation.OpId); throw new CloudFailure("invalid_request");
    }
    About[about.Operation] = new AboutRow { Body = AboutJson(about), Signer = signer.ToLowerInvariant() };
  }
  /// This device's own about-record for one of its journaled removals (sender side).
  public CloudDeleteIntent? IntentFor(CloudOperation removal, string place)
  {
    if (!About.TryGetValue(removal.OpId, out var row)) return null;
    if (AboutOf(row.Body) is not { } about || about.Place != place || !string.Equals(about.Mac, removal.OriginDevice, StringComparison.OrdinalIgnoreCase)
      || about.Travel.Intent is not { } intent) throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidTravelFields);
    return intent;
  }
  /// How an ARRIVING removal is applied: Everywhere only with its own valid about-record from the same verified signer
  /// at the same place; otherwise the safe way, unless its signer never announced the delete rule (old Everywhere).
  public CloudDeleteTravelRemoval ArrivedRemoval(CloudOperation removal, string place, string signer, bool announced)
  {
    var safe = new CloudDeleteTravelRemoval(CloudFileDeleteRecords.SafeIntent(removal, place, signer));
    if (About.TryGetValue(removal.OpId, out var row))
    {
      if (AboutOf(row.Body) is not { } about || row.Signer != signer.ToLowerInvariant() || !string.Equals(about.Mac, signer, StringComparison.OrdinalIgnoreCase)
        || about.Place != place) return safe;
      try { return about.Travel.Intent is { } intent ? new(intent) : safe; } catch (CloudDeleteRuleException) { return safe; }
    }
    if (Refused.Contains(CloudFileDeleteRecords.AboutId(removal.OpId))) return safe;
    return announced ? safe : CloudDeleteTravelRemoval.OlderVersion;
  }
  public void SaveHead(string place, string version, IReadOnlyList<string> parents, long at, string mac, CloudDeleteTravelRemoval travel)
  {
    var fields = new Dictionary<string, string>(StringComparer.Ordinal);
    if (travel.Intent is { } intent) CloudDeleteTravel.Write(intent, fields);
    Heads[place] = new HeadRow { Place = place, Version = version, Parents = parents.ToList(), At = at, Mac = mac, Fields = fields };
  }
  public static CloudFileDeleteRecords.Head HeadOf(HeadRow h) => new(h.Place, h.Version, h.Parents.ToArray(), h.At, h.Mac, h.Fields);
  public void DropHead(string place) { Heads.Remove(place); Applying.Remove(place); }
  public void SetRowError(string place, string? line, long at) { if (line is null) RowErrors.Remove(place); else RowErrors[place] = new RowError { Line = line, At = at }; }
}
