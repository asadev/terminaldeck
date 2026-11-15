using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Cloud;

// Lane F (15 Nov), the Mac's BackendCloudArtifacts.swift: an artifact made on one device (a page, a report, a picture:
// whatever the Artifacts page lists) is on his other devices' Artifacts pages too, with its name, project, the agent
// that made it and the date, and opens there.
//
// How: the Cloud folder's owner (CloudFolderOwner, the same engine, gate, limits, adoption and sweep guard) runs a
// second time with `CloudFileKind.Artifacts` over an app-private STORE:
//
//     <account>\artifacts-files\<project id>\<path inside the project>          the artifact's bytes
//     <account>\artifacts-files\<project id>\<path inside the project>.tdabout  its description
//
// This class feeds the store from the Artifacts page's own list (`Feed`, read only from Core/Receiver): a copy of each
// artifact inside a project folder, never a file outside the catalogue, never one over 25 MB, never one that is or holds
// a secret by the app's own rules. His project folders are only READ; nothing that arrives is ever written into them.
// Project-file disappearance and catalogue aging never remove a stored artifact. A by-hand store disappearance is a
// local mark; an explicit page/tool removal or witnessed AI command travels through the owner's intent and Bin.

public static class CloudArtifactsFormat
{
  public const string InventoryRow = "I23";
  public static string Domain => CloudFolderFormat.DomainOf(InventoryRow);
  public const string Feature = "artifacts";
  public const int Format = 1;
  public const long MaximumFileBytes = 25_000_000;
  public const long MaximumStoreBytes = 1_000_000_000;
  public const string AboutSuffix = ".tdabout";
  public static bool IsAbout(string path) => path.EndsWith(AboutSuffix, StringComparison.Ordinal);
  /// `<project id>/<path inside the project>`; null for anything that is not a plain path inside a project.
  public static string? StorePath(string projectId, string relPath)
  {
    if (relPath.StartsWith('/') || IsAbout(relPath) || projectId.Length == 0 || projectId.Contains('/') || CloudBootFilesFormat.Parts(projectId)?.Length != 1
      || !CloudBootFilesFormat.CleanRelative(relPath)) return null;
    var path = projectId + "/" + relPath;
    return CloudBootFilesFormat.CleanRelative(path) && CloudBootFilesFormat.Parts(path) is { Length: >= 2 } ? path : null;
  }
  /// Files whose words are read before they travel (pages, documents, data). Pictures, recordings and PDFs are not.
  private static readonly IReadOnlySet<string> TextEndings = new HashSet<string> { "html", "htm", "md", "markdown", "txt", "json", "csv", "tsv", "xml", "svg", "yaml", "yml",
    "js", "mjs", "css", "log", "rtf", "tex", "ipynb", "sql", "sh", "toml", "ini" };
  /// True when the artifact holds a secret by the app's own rules.
  public static bool HoldsSecret(string relPath, byte[] bytes) =>
    TextEndings.Contains(CloudArtifactRules.ExtensionOf(relPath)) && CloudArtifactSecrets.ContainsKnownSecret(Encoding.UTF8.GetString(bytes));

  public const string FullLine = "Your artifacts in the Cloud hold more than 1 GB. New and changed artifacts stay on this PC until there is room.";
  public const string DayFullLine = CloudFolderFormat.DayFullLine;
  public static string BusyLine(int count) => count == 1
    ? "1 artifact changed more than 6 times today. It is sent once it has been still for an hour."
    : count.ToString(CultureInfo.InvariantCulture) + " artifacts changed more than 6 times today. Each is sent once it has been still for an hour.";
  public const string RoomLowLine = "Your Cloud account has less than 3 GB of room left, so artifacts are not sent. Memory and everything else keep travelling.";
  public const string DiskLowLine = "This PC has less than 2 GB free, so artifacts from your other devices wait until there is more room.";
  public static string TooLargeLine(int count) => count == 1
    ? "1 artifact larger than 25 MB stays on this PC (artifacts up to 25 MB travel)."
    : count.ToString(CultureInfo.InvariantCulture) + " artifacts larger than 25 MB stay on this PC (artifacts up to 25 MB travel).";
  public static string SecretNameLine(IReadOnlyList<string> names) =>
    (names.Count == 1 ? "1 artifact stays on this PC because it is, or holds, a key, password or sign-in: "
      : names.Count.ToString(CultureInfo.InvariantCulture) + " artifacts stay on this PC because they are, or hold, a key, password or sign-in: ") + CloudFolderFormat.Names(names) + ".";
  public static string SpellingLine(IReadOnlyList<string> names) =>
    (names.Count == 1 ? "1 artifact stays on this PC because its name is spelled with separate accent marks: "
      : names.Count.ToString(CultureInfo.InvariantCulture) + " artifacts stay on this PC because their names are spelled with separate accent marks: ") + CloudFolderFormat.Names(names) + ".";
  public static string ClashLine(IReadOnlyList<string> names) =>
    (names.Count == 1 ? "1 artifact stays apart because its name is a file on one device and a folder on another: "
      : names.Count.ToString(CultureInfo.InvariantCulture) + " artifacts stay apart because their names are a file on one device and a folder on another: ") + CloudFolderFormat.Names(names) + ".";
  public static string GateLine(IReadOnlyList<string> devices)
  {
    var sorted = devices.Distinct().OrderBy(n => n, StringComparer.Ordinal).ToArray();
    return "Artifacts are not sent yet: " + CloudFolderFormat.List(sorted) + (devices.Count == 1 ? " has" : " have") + " not updated Terminal Deck or "
      + (devices.Count == 1 ? "has" : "have") + " Cloud off.";
  }
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Artifacts made outside a project's folder stay on this PC.",
    "Keys, environment and sign-in files, and artifacts that hold a key or password, never travel.",
    "Hidden and temporary files stay on this PC."
  ];
  /// "From MacBook Pro": the quiet line on the Artifacts page for an artifact another device made.
  public static string FromLine(string device) => "From " + device;
}

/// The Mac's ArtifactRules, the part the store uses (what kind a file is, in one word a person knows).
public static class CloudArtifactRules
{
  private static readonly Dictionary<string, string> KindByExtension = Build();
  private static Dictionary<string, string> Build()
  {
    var map = new Dictionary<string, string>(StringComparer.Ordinal);
    void Add(string kind, string extensions) { foreach (var ext in extensions.Split(' ')) map[ext] = kind; }
    Add("Document", "md markdown txt rtf pdf doc docx");
    Add("Web page", "html htm xhtml");
    Add("Style sheet", "css scss sass less");
    Add("Image", "png jpg jpeg gif webp svg avif ico bmp heic heif");
    Add("Video", "mp4 m4v mov webm");
    Add("Sound", "mp3 m4a wav aac flac ogg");
    Add("Data", "csv tsv json jsonl ndjson xml yaml yml toml sql geojson parquet");
    Add("Code", "ts tsx js jsx mjs cjs py rb go rs java kt swift c h cpp hpp cs php sh bash zsh ps1 lua vue svelte");
    Add("Notebook", "ipynb");
    return map;
  }
  public static string LastComponent(string relPath) => relPath.LastIndexOf('/') is var slash and >= 0 ? relPath[(slash + 1)..] : relPath;
  public static string ExtensionOf(string relPath)
  {
    var name = LastComponent(relPath);
    var dot = name.LastIndexOf('.');
    return dot <= 0 ? "" : name[(dot + 1)..].ToLowerInvariant();
  }
  public static string KindOf(string relPath)
  {
    var name = LastComponent(relPath);
    if (name.StartsWith('.') && !name[1..].Contains('.')) return "Setting";
    var ext = ExtensionOf(relPath);
    return ext.Length == 0 ? "File" : KindByExtension.GetValueOrDefault(ext) ?? "File";
  }
}

/// The Mac's BackendSharedRedact.containsKnownSecret, read only: key blocks, sign-ins inside links, secret headers,
/// quoted secret values, bearer values, the pair rule and every token shape. Left out, as on the Mac: the user-name rule,
/// the bare `name = value` rule (ordinary code in a page) and the high-randomness sweep (pictures written into a page).
public static class CloudArtifactSecrets
{
  private const string SecretHeaders = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token";
  private const string SecretKey = @"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*";
  private static Regex R(string pattern, bool insensitive = false) =>
    new(pattern, RegexOptions.CultureInvariant | (insensitive ? RegexOptions.IgnoreCase : RegexOptions.None), TimeSpan.FromSeconds(2));
  private static readonly Regex[] Structural =
  [
    R(@"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"),
    R(@"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"),
    R(@"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@", true),
    R("(\"(?:" + SecretHeaders + ")\"\\s*:\\s*)\"[^\"]*\"", true),
    R(@"\b((?:" + SecretHeaders + @")\s*:\s*)[^\r\n""']+", true),
    R(@"\b(" + SecretKey + @")(""?\s*[:=]\s*)([""'])(?:\\.|(?!\3)[^\\])*\3", true),
    R(@"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}", true),
    R(@"\b(password|passwd|pwd|secret|api[_\- ]?key|access[_\- ]?token|auth[_\- ]?token|token)\b(\s*[:=]\s*[""']?)(?=[^\s""',;]*\d)[^\s""',;]{6,}", true)
  ];
  private static readonly Regex[] Tokens =
  [
    R(@"\bsk-ant-[A-Za-z0-9_-]{10,}"), R(@"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}"), R(@"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"),
    R(@"\bgithub_pat_[A-Za-z0-9_]{20,}"), R(@"\bglpat-[A-Za-z0-9_-]{16,}"), R(@"\bxox[abprse]-[A-Za-z0-9-]{10,}"), R(@"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"),
    R(@"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"), R(@"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b"), R(@"\bAIza[A-Za-z0-9_-]{30,}"),
    R(@"\bya29\.[A-Za-z0-9_-]{10,}"), R(@"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}"), R(@"\bnpm_[A-Za-z0-9]{30,}"), R(@"\bdop_v1_[a-f0-9]{40,}"),
    R(@"\bhf_[A-Za-z0-9]{20,}"), R(@"\bsbp_[a-f0-9]{20,}"), R(@"\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}"), R(@"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"),
    R(@"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")
  ];
  public static bool ContainsKnownSecret(string text)
  {
    if (text.Length == 0) return false;
    try { return Structural.Any(r => r.IsMatch(text)) || Tokens.Any(r => r.IsMatch(text)); }
    catch (RegexMatchTimeoutException) { return true; }
  }
}

/// The description that travels beside each artifact. Never a path outside the project, never a session id.
public sealed record CloudArtifactAbout(string Name, string Project, string ProjectId, string? MadeBy, long CreatedAt, string Type, string Device, int V = 1)
{
  /// Equal apart from the device that wrote it (another device never rewrites a description only to put its own id in).
  public bool SameAs(CloudArtifactAbout o) => Name == o.Name && Project == o.Project && ProjectId == o.ProjectId && MadeBy == o.MadeBy && CreatedAt == o.CreatedAt && Type == o.Type;
  /// Sorted keys, no `madeBy` when not known (the Mac's JSONEncoder output, read by field on every device).
  public byte[] Encode()
  {
    var fields = new SortedDictionary<string, object?>(StringComparer.Ordinal)
    {
      ["createdAt"] = CreatedAt, ["device"] = Device, ["name"] = Name, ["project"] = Project, ["projectId"] = ProjectId, ["type"] = Type, ["v"] = V
    };
    if (MadeBy is not null) fields["madeBy"] = MadeBy;
    return JsonSerializer.SerializeToUtf8Bytes(fields);
  }
  public static CloudArtifactAbout? Decode(byte[] bytes)
  {
    try
    {
      using var doc = JsonDocument.Parse(bytes);
      var r = doc.RootElement;
      string S(string k) => r.GetProperty(k).GetString() ?? throw new JsonException();
      return new(S("name"), S("project"), S("projectId"), r.TryGetProperty("madeBy", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() : null,
        r.GetProperty("createdAt").GetInt64(), S("type"), S("device"), r.TryGetProperty("v", out var v) ? v.GetInt32() : 1);
    }
    catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException) { return null; }
  }
}

/// One artifact as the Artifacts page lists it (from the page's own catalogue).
public sealed record CloudArtifactEntry(string ProjectId, string ProjectName, string Root, string RelPath, string Name, string? MadeBy, long CreatedAt);

/// One artifact in the store (made here or on another device), as the page and the tools show it.
public sealed record CloudArtifactItem(string Path, string ProjectId, string RelPath, string Name, string? Project, string? MadeBy, long CreatedAt, long ChangedAt,
  string Type, long Bytes, string? Device, string File);

public sealed class CloudArtifacts : ICloudDeleteOwning
{
  /// The Cloud folder's owner over the artifacts store.
  public CloudFolderOwner Owner { get; }
  public string Store { get; }
  private readonly string stateRoot;
  public string DeviceId { get; }
  private readonly CloudFileSlot feedSlot;
  private readonly Dictionary<string, Fed> fed;
  private readonly object gate = new();

  private sealed class Fed { public long Bytes { get; set; } public long Modified { get; set; } public string State { get; set; } = ""; public string Name { get; set; } = ""; }

  /// - `store`: `<account>\artifacts-files` (the app's own folder; never his projects).
  /// - `stateRoot`: `<account>\artifacts` (the owner's state is `<stateRoot>\owner`).
  public CloudArtifacts(string deviceId, string store, string stateRoot, CloudBin keeper, Func<bool> everyDeviceUnderstands, Func<long?>? freeDisk = null,
    Func<long>? now = null, Action<string>? log = null)
  {
    Owner = new CloudFolderOwner(deviceId, store, Path.Combine(stateRoot, "owner"), keeper, everyDeviceUnderstands, CloudFileKind.Artifacts, freeDisk, now, log);
    Store = Owner.Folder;
    this.stateRoot = Path.GetFullPath(stateRoot);
    DeviceId = deviceId.ToLowerInvariant();
    feedSlot = new CloudFileSlot(Path.Combine(this.stateRoot, "feed.json"));
    fed = feedSlot.Read() is { } bytes ? JsonSerializer.Deserialize<Dictionary<string, Fed>>(bytes) ?? [] : [];
  }
  private void SaveFeed() { lock (gate) feedSlot.Write(JsonSerializer.SerializeToUtf8Bytes(fed)); }

  /// The store, made once when artifacts start on this PC (never again by itself: a store that is gone later is said on
  /// the Cloud page and "Make it again" makes it again, as the Cloud folder does).
  public void PrepareStore()
  {
    var ledger = Path.Combine(stateRoot, "store-made");
    if (File.Exists(ledger)) return;
    Directory.CreateDirectory(Store);
    new CloudFileSlot(ledger).Write("1"u8.ToArray());
  }

  /// The catalogue's entries for the store, from the Receiver's recorded outputs: an artifact inside its project's one
  /// folder on this PC, by its path inside that folder. Hidden catalogue rows and outputs outside the project stay out.
  public static IReadOnlyList<CloudArtifactEntry> EntriesFrom(IEnumerable<ReceiverArtifact> artifacts, Func<string, (string Name, string Folder)?> project)
  {
    var entries = new List<CloudArtifactEntry>();
    foreach (var artifact in artifacts.Where(a => !a.Hidden))
    {
      if (project(artifact.ProjectId) is not { } known || !Path.IsPathFullyQualified(known.Folder) || !Path.IsPathFullyQualified(artifact.Cwd)) continue;
      string root, full;
      try { root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(known.Folder)); full = Path.GetFullPath(Path.Combine(artifact.Cwd, artifact.RelPath)); }
      catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { continue; }
      if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) continue;
      var relPath = full[(root.Length + 1)..].Replace('\\', '/');
      entries.Add(new CloudArtifactEntry(artifact.ProjectId, known.Name, root, relPath, CloudArtifactRules.LastComponent(relPath), null, artifact.ProducedAt.ToUnixTimeMilliseconds()));
    }
    return entries;
  }

  /// Copies each listed artifact that is new or changed since it was last copied into the store. Nothing before this PC
  /// has read the Cloud; nothing that is or holds a secret; nothing over 25 MB (counted, said on the page); never a file
  /// outside its project folder, through a link, or still being written. Returns how many it copied.
  public async Task<int> FeedAsync(IReadOnlyList<CloudArtifactEntry> entries)
  {
    if (!Owner.HasReadCloud()) return 0;
    var copied = 0;
    foreach (var entry in entries)
    {
      if (CloudArtifactsFormat.StorePath(entry.ProjectId, entry.RelPath) is not { } path) continue;
      // Never recreate a store file which the person removed or kept local-only, even if its project changes.
      if (Owner.LocalMark(path) is not null) continue;
      if (!Path.IsPathFullyQualified(entry.Root) || CloudFolderDisk.StampOf(entry.Root, entry.RelPath) is not { } stamp) continue;
      Fed? held;
      lock (gate) held = fed.GetValueOrDefault(path);
      // Unchanged since it was last looked at (copied, removed by him, or kept here): nothing to do.
      if (held is not null && held.Bytes == stamp.Bytes && held.Modified == stamp.Modified) continue;
      void Mark(string what) { lock (gate) fed[path] = new Fed { Bytes = stamp.Bytes, Modified = stamp.Modified, State = what, Name = entry.Name }; SaveFeed(); }
      switch (Owner.Profile.Refusal(path))
      {
        case null: break;
        case CloudFolderSkip.Secret: Mark("secret"); continue;
        default: continue;
      }
      if (stamp.Bytes > CloudArtifactsFormat.MaximumFileBytes) { Mark("large"); continue; }
      var read = CloudFolderDisk.Read(entry.Root, entry.RelPath);
      if (!read.IsFile || CloudFolderDisk.StampOf(entry.Root, entry.RelPath) != stamp || read.Bytes!.LongLength != stamp.Bytes) continue;
      var bytes = read.Bytes!;
      if (CloudArtifactsFormat.HoldsSecret(entry.RelPath, bytes)) { Mark("secret"); continue; }
      var hash = CloudMemoryFormat.Hash(bytes);
      string? expecting;
      var there = CloudFolderDisk.Read(Store, path);
      if (there.Kind == CloudFolderDisk.Kind.Blocked) continue;
      if (there.IsFile)
      {
        var thereHash = CloudMemoryFormat.Hash(there.Bytes!);
        if (thereHash == hash) { Mark("fed"); continue; }
        // A copy from another device is in the store and this PC never copied its own: only a NEWER file of his
        // replaces it (two devices that both have the project never send an older file over a newer one).
        if (held is null && CloudFolderDisk.StampOf(Store, path)?.Modified is { } at && at >= stamp.Modified) { Mark("fed"); continue; }
        expecting = thereHash;
      }
      else expecting = null;
      try { await Owner.StoreWriteAsync(path, bytes, stamp.Modified, expecting); }
      catch (CloudFailure) { continue; }
      try { await WriteAboutAsync(path, entry); } catch (CloudFailure) { }
      Mark("fed");
      copied++;
    }
    return copied;
  }
  /// The description beside the artifact, written only when it is new or says something different.
  private async Task WriteAboutAsync(string path, CloudArtifactEntry entry)
  {
    var about = new CloudArtifactAbout(entry.Name, entry.ProjectName, entry.ProjectId, entry.MadeBy, entry.CreatedAt, CloudArtifactRules.KindOf(entry.RelPath), DeviceId);
    var aboutPath = path + CloudArtifactsFormat.AboutSuffix;
    string? expecting = null;
    var there = CloudFolderDisk.Read(Store, aboutPath);
    if (there.Kind == CloudFolderDisk.Kind.Blocked) return;
    if (there.IsFile)
    {
      if (CloudArtifactAbout.Decode(there.Bytes!) is { } held && held.SameAs(about)) return;
      expecting = CloudMemoryFormat.Hash(there.Bytes!);
    }
    await Owner.StoreWriteAsync(aboutPath, about.Encode(), null, expecting);
  }

  /// Every artifact in the store (made here or on another device), newest change first.
  public IReadOnlyList<CloudArtifactItem> Items()
  {
    var walk = CloudFolderWalk.Run(Store);
    var made = new List<CloudArtifactItem>();
    foreach (var (path, entry) in walk.Files)
    {
      if (CloudArtifactsFormat.IsAbout(path) || path.IndexOf('/') is not (> 0 and var slash)) continue;
      string projectId = path[..slash], relPath = path[(slash + 1)..];
      var about = CloudFolderDisk.Read(Store, path + CloudArtifactsFormat.AboutSuffix) is { IsFile: true } a ? CloudArtifactAbout.Decode(a.Bytes!) : null;
      if (about is not null && about.ProjectId != projectId) about = null;
      made.Add(new CloudArtifactItem(path, projectId, relPath, about?.Name ?? CloudArtifactRules.LastComponent(relPath), about?.Project, about?.MadeBy,
        about?.CreatedAt ?? entry.Modified, entry.Modified, about?.Type ?? CloudArtifactRules.KindOf(relPath), entry.Bytes, about?.Device, CloudFolderDisk.Full(Store, path)));
    }
    return made.OrderByDescending(i => i.ChangedAt).ThenBy(i => i.Path, StringComparer.Ordinal).ToArray();
  }
  public (int Artifacts, long Bytes) Counts() { var all = Items(); return (all.Count, all.Sum(i => i.Bytes)); }

  /// Delete from the list is one explicit Everywhere group. The project's original is never touched.
  public async Task<bool> RemoveAsync(string path, bool fromAi = false)
  {
    if (CloudArtifactsFormat.IsAbout(path) || !CloudFolderDisk.Read(Store, path).IsFile) return false;
    var person = Owner.PersonActor();
    var actor = person with { By = fromAi ? CloudDeleteBy.Ai : CloudDeleteBy.Person };
    await DeleteItemsAsync([new CloudDeleteItem(path, Owner.Profile.KeeperKind, CloudArtifactRules.LastComponent(path), path)], CloudDeleteScope.Everywhere, actor);
    return true;
  }
  /// Put back from the Bin: the artifact and its description come back in the store and travel again.
  public async Task<bool> PutBackAsync(string path)
  {
    if (!await Owner.PutBackAsync(path)) return false;
    try { await Owner.PutBackAsync(path + CloudArtifactsFormat.AboutSuffix); } catch (CloudFailure) { }
    return true;
  }
  /// The Bin of artifacts on this PC (descriptions are not items). `Place` is the project's name when known.
  public IReadOnlyList<CloudFolderKept> Bin(IReadOnlyDictionary<string, string>? projects = null) =>
    Owner.Bin().Where(k => !CloudArtifactsFormat.IsAbout(k.Path)).Select(k =>
    {
      var projectId = k.Path.Split('/')[0];
      return k with { Place = projects?.GetValueOrDefault(projectId) ?? "A project not on this PC" };
    }).ToArray();
  /// The page's lines for artifacts: the owner's own (gate, limits, room, disk) and what the feed kept on this PC.
  public IReadOnlyList<string> PageLines()
  {
    var lines = Owner.PageLines().ToList();
    Fed[] rows;
    lock (gate) rows = fed.Values.ToArray();
    var large = rows.Count(r => r.State == "large");
    if (large > 0) lines.Add(CloudArtifactsFormat.TooLargeLine(large));
    var secret = rows.Where(r => r.State == "secret").Select(r => r.Name).OrderBy(n => n, StringComparer.Ordinal).ToArray();
    if (secret.Length > 0) lines.Add(CloudArtifactsFormat.SecretNameLine(secret));
    return lines;
  }

  // ---- The delete rule (an artifact and its description together, one group) ----

  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    var all = items.ToList();
    foreach (var item in items)
    {
      if (CloudArtifactsFormat.IsAbout(item.Id) || Owner.Profile.Refusal(item.Id) is not null) throw new CloudFailure("invalid_request");
      var about = item.Id + CloudArtifactsFormat.AboutSuffix;
      if (CloudFolderDisk.Read(Store, about).IsFile) all.Add(new CloudDeleteItem(about, Owner.Profile.KeeperKind, CloudArtifactRules.LastComponent(about), about));
    }
    var group = await Owner.DeleteItemsAsync(all, scope, by);
    // Only what was really removed (one item that failed never stops the rest).
    var removed = group.Items.Select(i => i.Id).ToHashSet(StringComparer.Ordinal);
    var done = items.Where(i => removed.Contains(i.Id)).ToArray();
    lock (gate) foreach (var item in done) if (fed.TryGetValue(item.Id, out var row)) row.State = "removed";
    SaveFeed();
    return group with { Items = done };
  }
  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    var all = items.ToList();
    foreach (var item in items)
    {
      var about = item.Id + CloudArtifactsFormat.AboutSuffix;
      if (Owner.LocalMark(about) is not null || File.Exists(CloudFolderDisk.Full(Store, about)))
        all.Add(new CloudDeleteItem(about, Owner.Profile.KeeperKind, CloudArtifactRules.LastComponent(about), about));
    }
    await Owner.BringBackAsync(all, to);
    return items;
  }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Owner.NotHereAsync();
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => Owner.BinGroupsAsync();
  /// Every entry of the group comes back, each artifact's description too (they share the group). Answers the artifacts.
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group) =>
    (await Owner.PutBackGroupAsync(group)).Where(i => !CloudArtifactsFormat.IsAbout(i.Id)).ToArray();
  public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items) =>
    Owner.DeleteForGoodAsync(items.Concat(items.Select(i => new CloudDeleteItem(i.Id + CloudArtifactsFormat.AboutSuffix, Owner.Profile.KeeperKind, i.Name, i.Place))).ToArray());
}
