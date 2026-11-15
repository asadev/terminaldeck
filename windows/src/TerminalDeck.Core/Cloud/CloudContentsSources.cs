using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Cloud;

// Lane U1 (15 Nov): one small provider per kind for "what is in your Cloud" (CloudContents) and the shelf (CloudShelf).
// Each reads its kind's own owner or folder, read only; removals go through the owner's ICloudDeleteOwning. Row ids
// follow the Mac's page ids ("<kind>|<place>|<path>"), never shown. Kinds with no provider yet (saved passwords and
// project secret files, tasks, agents and projects in record version 2) are registered by their lanes' join with the
// same interface; nothing here has to change for them.

/// What the shelf needs from a provider beyond its rows: whether a row is text, its text (what the page shows when it
/// is opened) and, for a file kind, where its bytes are on this PC. Optional: a provider without it puts rows only.
public interface ICloudShelfReadable
{
  bool IsText(CloudContentsRow row);
  Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel);
  /// The folder and relative path of a Cloud folder or artifact file (nil for every other kind).
  (string Root, string Relative)? FileAt(CloudContentsRow row) => null;
  /// A task's state or an agent's role in words (the shelf's `status`); default the row's own detail.
  string? Status(CloudContentsRow row) => row.Detail;
  /// A grouped table (the diary): its date, size and count never make a put by themselves.
  bool Grouped(CloudContentsRow row) => false;
}

public static class CloudContentsText
{
  public const int TextMaxBytes = 1_048_576;
  private static readonly string[] TextEndings = [".md", ".markdown", ".txt", ".json", ".yaml", ".yml", ".toml", ".csv", ".log", ".html", ".css", ".js", ".ts",
    ".py", ".sh", ".ps1", ".xml", ".ini", ".cfg", ".swift", ".cs", ".go", ".rs", ".java", ".rb", ".sql"];
  public static bool LooksText(string relative) => TextEndings.Any(e => relative.EndsWith(e, StringComparison.OrdinalIgnoreCase));
  /// UTF-8 text of at most 1 MB with no zero byte; null otherwise.
  public static string? Text(byte[]? bytes)
  {
    if (bytes is null || bytes.Length > TextMaxBytes || Array.IndexOf(bytes, (byte)0) >= 0) return null;
    try { return new UTF8Encoding(false, true).GetString(bytes); } catch (DecoderFallbackException) { return null; }
  }
  public static long Ms(long ticks) => ticks > DateTime.UnixEpoch.Ticks ? (ticks - DateTime.UnixEpoch.Ticks) / TimeSpan.TicksPerMillisecond : Math.Max(0, ticks);
  public static string Last(string relative) => relative.Split('/')[^1];
  public static IReadOnlyList<string> Folders(string relative) => relative.Split('/')[..^1];
}

/// Memory: one row per note file (never `archive/`, the app's own help files or the memory's index), named by its
/// title, in the folders a person gave it. "Bin" and "Not on this PC" through the memory adapter's delete rule.
public sealed class CloudMemoryContentsSource(IDeckMemoryCloudStore store, ICloudDeleteOwning? removals = null,
  Func<IReadOnlyDictionary<string, string>>? names = null) : ICloudContentsSource, ICloudShelfReadable
{
  public CloudContentsKind Kind => CloudContentsKind.Memory;
  public ICloudDeleteOwning? Removals => removals;
  public CloudDeleteItem DeleteItem(CloudContentsRow row) => CloudMemoryAdapter.Item(PathOf(row));
  private static readonly HashSet<string> Generic = new(StringComparer.OrdinalIgnoreCase) { "notes", "topics", "handoffs", "projects", "roles", "leads", "team", "files", "" };

  private static string PathOf(CloudContentsRow row) => row.Id[(row.Id.IndexOf('|', "memory|".Length) + 1)..];
  public static bool Listed(string path) => DeckMemoryCloudSchema.SafePath(path) && !path.StartsWith("archive/", StringComparison.Ordinal)
    && !DeckMemoryCloudSchema.AppHelpFiles.Contains(path) && CloudContentsText.Last(path) != "MEMORY.md"
    && !Regex.IsMatch(path, "-cloud-[0-9a-f]{16}\\.md$");

  public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var known = names?.Invoke() ?? new Dictionary<string, string>();
    var rows = new List<CloudContentsRow>();
    foreach (var file in store.ListFiles())
    {
      if (!Listed(file.Path)) continue;
      var folder = CloudContentsText.Folders(file.Path).Where(p => !Generic.Contains(p)).Select(p => CloudShelfWords.Plain(known.GetValueOrDefault(p) ?? p))
        .OfType<string>().ToArray();
      var name = Title(file.Path) ?? CloudContentsWords.Title(Kind);
      rows.Add(new CloudContentsRow("memory|" + string.Join(" · ", folder) + "|" + file.Path, Kind, name, folder, CloudContentsText.Ms(file.ModifiedTicks), null,
        file.Length, CloudItemState.InSync));
    }
    return Task.FromResult<IReadOnlyList<CloudContentsRow>>(rows);
  }

  /// The note's own title (its first heading or `title:` line), else its file name made readable.
  private string? Title(string path)
  {
    if (path.EndsWith(".md", StringComparison.OrdinalIgnoreCase) && CloudContentsText.Text(store.ReadFile(path)) is { } text)
      foreach (var line in text.Split('\n').Take(40))
      {
        var t = line.Trim();
        if (t.StartsWith("title:", StringComparison.OrdinalIgnoreCase) && CloudShelfWords.Plain(t[6..].Trim().Trim('"')) is { } a) return a;
        if (t.StartsWith("# ", StringComparison.Ordinal) && CloudShelfWords.Plain(t[2..]) is { } b) return b;
      }
    return CloudShelfWords.FileWords(Path.GetFileNameWithoutExtension(CloudContentsText.Last(path)));
  }

  public bool IsText(CloudContentsRow row) => CloudContentsText.LooksText(PathOf(row));
  public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult(Shown(CloudContentsText.Text(store.ReadFile(PathOf(row)))));

  /// A note without its label block (the front matter between two `---` lines).
  public static string? Shown(string? text)
  {
    if (text is null || !text.StartsWith("---\n", StringComparison.Ordinal)) return text;
    var end = text.IndexOf("\n---\n", 4, StringComparison.Ordinal);
    return end < 0 ? text : text[(end + 5)..].TrimStart('\n');
  }

  public async Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) =>
    new(row.Name, row.ChangedAt, await TextAsync(row, cancel), null, "text/markdown", Where(row));
  internal static string? Where(CloudContentsRow row) => row.State == CloudItemState.InSync ? null : CloudContentsWords.On(row.State);
}

/// One instruction-file place: its source id (CloudBootFilesFormat.SourceId), its folder on this PC and its name.
public sealed record CloudBootFilesPlace(string SourceId, CloudBootFilesPlaceKind Kind, string Root, string Name);

/// Instruction files: every listed file present in each place (project folders and the AI homes), by its own name in
/// its place's folder. A project's files are removed through the instruction files' delete rule; a home's are not.
public sealed class CloudBootFilesContentsSource(Func<IReadOnlyList<CloudBootFilesPlace>> places, ICloudDeleteOwning? removals = null)
  : ICloudContentsSource, ICloudShelfReadable
{
  public CloudContentsKind Kind => CloudContentsKind.InstructionFiles;
  public ICloudDeleteOwning? Removals => removals;
  private readonly Dictionary<string, (CloudBootFilesPlace Place, string Relative)> where = new(StringComparer.Ordinal);

  public CloudDeleteItem DeleteItem(CloudContentsRow row)
  {
    var (place, relative) = Locate(row) ?? throw new CloudFailure("invalid_request");
    if (place.Kind != CloudBootFilesPlaceKind.Project) throw new CloudFailure("invalid_request");
    return CloudBootFilesAdapter.Item(place.SourceId, relative);
  }
  private (CloudBootFilesPlace, string)? Locate(CloudContentsRow row) { lock (where) return where.TryGetValue(row.Id, out var w) ? w : null; }

  public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var rows = new List<CloudContentsRow>();
    var found = new Dictionary<string, (CloudBootFilesPlace, string)>(StringComparer.Ordinal);
    foreach (var place in places())
    {
      var placeName = CloudShelfWords.Plain(place.Name) ?? "Instruction files";
      foreach (var relative in Present(place))
      {
        if (CloudFolderDisk.StampOf(place.Root, relative) is not { } stamp) continue;
        var id = "instructionFiles|" + placeName + "|" + relative;
        if (found.ContainsKey(id)) continue;
        found[id] = (place, relative);
        var folder = new List<string> { placeName };
        folder.AddRange(CloudContentsText.Folders(relative).Where(p => !p.StartsWith('.')));
        rows.Add(new CloudContentsRow(id, Kind, CloudContentsText.Last(relative), folder, stamp.Modified, null, stamp.Bytes, CloudItemState.InSync));
      }
    }
    lock (where) { where.Clear(); foreach (var f in found) where[f.Key] = f.Value; }
    return Task.FromResult<IReadOnlyList<CloudContentsRow>>(rows);
  }

  /// The listed files of a place that exist on this PC: its named files, and the files of its listed folders (skills,
  /// agents, commands) at most `MaximumFolderDepth` deep, never a refused one.
  private static IEnumerable<string> Present(CloudBootFilesPlace place)
  {
    foreach (var name in CloudBootFilesFormat.Files(place.Kind)) yield return name;
    foreach (var folder in CloudBootFilesFormat.Folders(place.Kind))
    {
      var full = CloudFolderDisk.Full(place.Root, folder);
      if (!CloudFolderDisk.IsPlainFolder(full)) continue;
      IEnumerable<string> files;
      try { files = Directory.EnumerateFiles(full, "*", new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = CloudBootFilesFormat.MaximumFolderDepth, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.Hidden }).Take(CloudBootFilesFormat.MaximumFilesPerPlace).ToArray(); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
      foreach (var file in files)
      {
        var relative = Path.GetRelativePath(place.Root, file).Replace('\\', '/');
        if (CloudBootFilesFormat.Refusal(place.Kind, relative) is null) yield return relative;
      }
    }
  }

  public bool IsText(CloudContentsRow row) => true;
  public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel) =>
    Task.FromResult(Locate(row) is var (place, relative) && CloudFolderDisk.Read(place.Root, relative) is { IsFile: true } f ? CloudContentsText.Text(f.Bytes) : null);
  public async Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) =>
    new(row.Name, row.ChangedAt, await TextAsync(row, cancel), null, "text/markdown", CloudMemoryContentsSource.Where(row));
}

/// The Cloud folder: one row per file in his Cloud folder (the folder sync's own walk: no links, no refused names), in
/// its folders. Removals through the folder owner.
public sealed class CloudFolderContentsSource(CloudFolderOwner owner) : ICloudContentsSource, ICloudShelfReadable
{
  public CloudContentsKind Kind => CloudContentsKind.CloudFolder;
  public ICloudDeleteOwning? Removals => owner;
  private static string PathOf(CloudContentsRow row) => row.Id["cloudFolder||".Length..];
  public CloudDeleteItem DeleteItem(CloudContentsRow row) => new(PathOf(row), owner.Profile.KeeperKind, row.Name, PathOf(row));

  public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var walk = CloudFolderWalk.Run(owner.Folder);
    IReadOnlyList<CloudContentsRow> rows = walk.Files.Select(f => new CloudContentsRow("cloudFolder||" + f.Key, Kind, CloudContentsText.Last(f.Key),
      CloudContentsText.Folders(f.Key), f.Value.Modified, null, f.Value.Bytes, CloudItemState.InSync)).ToArray();
    return Task.FromResult(rows);
  }
  public bool IsText(CloudContentsRow row) => CloudContentsText.LooksText(PathOf(row));
  public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult(CloudShelf.FileText(owner.Folder, PathOf(row)));
  public (string Root, string Relative)? FileAt(CloudContentsRow row) => (owner.Folder, PathOf(row));
  public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult(CloudFileContents.Open(row, owner.Folder, PathOf(row)));
}

/// Artifacts: one row per artifact in the store (made here or on another device), in its project's folder.
public sealed class CloudArtifactsContentsSource(CloudArtifacts artifacts) : ICloudContentsSource, ICloudShelfReadable
{
  public CloudContentsKind Kind => CloudContentsKind.Artifacts;
  public ICloudDeleteOwning? Removals => artifacts;
  private static string PathOf(CloudContentsRow row) => row.Id[(row.Id.IndexOf('|', "artifacts|".Length) + 1)..];
  public CloudDeleteItem DeleteItem(CloudContentsRow row) => new(PathOf(row), artifacts.Owner.Profile.KeeperKind, row.Name, PathOf(row));

  public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    IReadOnlyList<CloudContentsRow> rows = artifacts.Items().Select(i =>
    {
      var project = CloudShelfWords.Plain(i.Project);
      return new CloudContentsRow("artifacts|" + (project ?? "") + "|" + i.Path, Kind, CloudShelfWords.Plain(i.Name) ?? CloudContentsText.Last(i.RelPath),
        project is null ? [] : [project], i.ChangedAt, CloudShelfWords.Plain(i.MadeBy), i.Bytes, CloudItemState.InSync);
    }).ToArray();
    return Task.FromResult(rows);
  }
  public bool IsText(CloudContentsRow row) => CloudContentsText.LooksText(PathOf(row));
  public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult(CloudShelf.FileText(artifacts.Store, PathOf(row)));
  public (string Root, string Relative)? FileAt(CloudContentsRow row) => (artifacts.Store, PathOf(row));
  public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult(CloudFileContents.Open(row, artifacts.Store, PathOf(row)));
}

internal static class CloudFileContents
{
  public static CloudOpenedItem? Open(CloudContentsRow row, string root, string relative)
  {
    if (CloudFolderDisk.Read(root, relative) is not { IsFile: true } found) return null;
    var type = CloudShelf.FileType(relative);
    var text = CloudContentsText.LooksText(relative) ? CloudContentsText.Text(found.Bytes) : null;
    return new CloudOpenedItem(row.Name, row.ChangedAt, text, text is null ? found.Bytes : null, type, CloudMemoryContentsSource.Where(row));
  }
}

/// Sessions and chats: every session's and earlier chat's copy in the Cloud (lane C's rows), by project; removed
/// Everywhere only. Opening one is the chat page's (the screens'), so rows here do not open.
public sealed class CloudSessionsContentsSource(Func<CancellationToken, Task<IReadOnlyList<CloudSessionsRead.Row>>> rows, ICloudDeleteOwning? removals = null)
  : ICloudContentsSource
{
  public CloudContentsKind Kind => CloudContentsKind.Sessions;
  public ICloudDeleteOwning? Removals => removals;
  public bool OffersCloudOnly => false;
  private readonly Dictionary<string, CloudDeleteItem> items = new(StringComparer.Ordinal);

  public CloudDeleteItem DeleteItem(CloudContentsRow row) { lock (items) return items.TryGetValue(row.Id, out var i) ? i : throw new CloudFailure("invalid_request"); }

  public async Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var entries = CloudChatsContents.Items(await rows(cancel));
    lock (items)
    {
      items.Clear();
      foreach (var e in entries) items[e.Id] = new CloudDeleteItem(e.DeleteItem.Id, e.DeleteItem.Kind, e.DeleteItem.Name, e.DeleteItem.Place);
    }
    return entries.Select(e => new CloudContentsRow(e.Id, Kind, e.Name, e.Folder, e.ChangedAt, e.Machine, null, CloudItemState.InSync, CanOpen: false)).ToArray();
  }
  public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult<CloudOpenedItem?>(null);
}

/// Settings: each setting about him that travels, by its name, grouped by its Settings page, its value in plain words
/// (`Detail`). Settings are not removed (the Mac offers no bin for them).
public sealed class CloudSettingsContentsSource(Func<IReadOnlyList<CloudSetting>> settings) : ICloudContentsSource, ICloudShelfReadable
{
  public CloudContentsKind Kind => CloudContentsKind.Settings;
  public ICloudDeleteOwning? Removals => null;
  public CloudDeleteItem DeleteItem(CloudContentsRow row) => throw new CloudFailure("invalid_request");

  /// The setting's name and its Settings page, by its record id (the Mac's names; unknown keys say their own words).
  private static readonly Dictionary<string, (string Name, string Page)> Names = new(StringComparer.Ordinal)
  {
    ["preference:restoreSessions"] = ("Reopen sessions at start", "General"),
    ["setting:general.autoNameSessions"] = ("Name sessions from the conversation", "General"),
    ["setting:general.copyOnSelect"] = ("Copy on select", "General"),
    ["preference:defaultProvider"] = ("Default coding AI", "General"),
    ["setting:appearance.terminalScheme"] = ("Terminal colours", "Appearance"),
    ["setting:appearance.terminalFontFamily"] = ("Terminal font", "Appearance"),
    ["setting:appearance.terminalFontSize"] = ("Terminal font size", "Appearance"),
  };

  public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var rows = new List<CloudContentsRow>();
    foreach (var s in settings())
    {
      var (name, page) = Names.TryGetValue(s.Entity, out var n) ? n : (CloudShelfWords.FileWords(s.Key.Split('.')[^1]) ?? "Setting", "Other");
      CloudJson value;
      try { value = s.Read(); } catch { continue; }
      rows.Add(new CloudContentsRow("settings||" + s.Entity, Kind, name, [page], 0, null, null, CloudItemState.InSync, CloudShelfWords.SettingValue(value), CanOpen: false));
    }
    return Task.FromResult<IReadOnlyList<CloudContentsRow>>(rows);
  }
  public bool IsText(CloudContentsRow row) => false;
  public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult<string?>(null);
  public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) => Task.FromResult<CloudOpenedItem?>(null);
}

/// Tasks, agents and projects (records version 2): one row per record of the owner, by its name; a task's state in words
/// as its detail; agents and projects in their project's folder when one is named. Removals through the owner
/// (tasks and agents always Everywhere).
public sealed class CloudRecordsContentsSource(CloudContentsKind kind, ICloudRecordOwner owner, ICloudDeleteOwning? removals,
  Func<IReadOnlyDictionary<string, string>>? projectNames = null) : ICloudContentsSource, ICloudShelfReadable
{
  public CloudContentsKind Kind => kind;
  public ICloudDeleteOwning? Removals => removals;
  public bool OffersCloudOnly => kind == CloudContentsKind.Projects;
  private string Prefix => kind switch { CloudContentsKind.Tasks => "task:", CloudContentsKind.Agents => "agent:", _ => "project:" };
  private string OwnerKind => kind switch { CloudContentsKind.Tasks => "task", CloudContentsKind.Agents => "agent", _ => "project" };
  private string Raw => CloudShelf.Raw(kind);
  private string EntityOf(CloudContentsRow row) => row.Id[(row.Id.IndexOf('|', Raw.Length + 1) + 1)..];
  public CloudDeleteItem DeleteItem(CloudContentsRow row) => new(EntityOf(row), OwnerKind, row.Name);

  private static CloudJson? Get(CloudJson.Object o, string key) => o.Members.FirstOrDefault(m => m.Key == key).Value;
  private static string? Text(CloudJson.Object o, string key) => Get(o, key) is CloudJson.String s ? s.Value : null;
  private static long Time(CloudJson.Object o) =>
    new[] { "updatedAt", "changedAt", "createdAt" }.Select(k => Get(o, k) is CloudJson.Number n ? (long)n.Value : 0).FirstOrDefault(v => v > 0);

  public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var names = projectNames?.Invoke() ?? new Dictionary<string, string>();
    var rows = new List<CloudContentsRow>();
    foreach (var (entity, value) in owner.CloudRecords())
    {
      if (!entity.StartsWith(Prefix, StringComparison.Ordinal)) continue;
      var name = CloudShelfWords.Plain(Text(value, kind == CloudContentsKind.Tasks ? "title" : "name")) ?? CloudContentsWords.Title(kind);
      var project = Text(value, "projectId") ?? (Get(value, "projectRef") is CloudJson.Object r ? Text(r, "projectId") : null);
      string[] folder = kind != CloudContentsKind.Projects && project is not null && CloudShelfWords.Plain(names.GetValueOrDefault(project)) is { } p ? new[] { p } : [];
      var detail = kind switch
      {
        CloudContentsKind.Tasks => CloudShelfWords.Plain(Text(value, "crmStatus")),
        CloudContentsKind.Agents => CloudShelfWords.Plain(Text(value, "role")),
        _ => null
      };
      rows.Add(new CloudContentsRow(Raw + "|" + string.Join(" · ", folder) + "|" + entity, kind, name, folder, Time(value), null, null, CloudItemState.InSync, detail,
        CanOpen: kind == CloudContentsKind.Tasks));
    }
    return Task.FromResult<IReadOnlyList<CloudContentsRow>>(rows);
  }

  /// A task's text: its description (`instructions`); other records have none.
  public bool IsText(CloudContentsRow row) => kind == CloudContentsKind.Tasks;
  public Task<string?> TextAsync(CloudContentsRow row, CancellationToken cancel)
  {
    if (kind != CloudContentsKind.Tasks || !owner.CloudRecords().TryGetValue(EntityOf(row), out var value)) return Task.FromResult<string?>(null);
    var text = Text(value, "instructions")?.Trim();
    return Task.FromResult(string.IsNullOrEmpty(text) || CloudArtifactSecrets.ContainsKnownSecret(text) ? null : text);
  }
  public async Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) =>
    kind == CloudContentsKind.Tasks ? new(row.Name, row.ChangedAt, await TextAsync(row, cancel), null, "text/plain", CloudMemoryContentsSource.Where(row)) : null;
}

/// Saved passwords (every travelling store: server sign-ins, API keys, MCP servers, SSH keys …) and project secret files:
/// one row per item by its NAME and folder, never a value. Opening one shows its name and date only. Removals go to the
/// store that holds the item (saved passwords by their source, secret files by their kind).
public sealed class CloudPasswordsContentsSource(Func<IReadOnlyList<CloudSecretsDeleteOwner>> stores, Func<CloudProjectSecretFilesStore?>? secretFiles = null)
  : ICloudContentsSource, ICloudDeleteOwning
{
  public CloudContentsKind Kind => CloudContentsKind.Passwords;
  public ICloudDeleteOwning? Removals => this;
  private readonly Dictionary<string, CloudDeleteItem> items = new(StringComparer.Ordinal);
  public const string SecretFilesFolder = "Secret files";

  public CloudDeleteItem DeleteItem(CloudContentsRow row) { lock (items) return items.TryGetValue(row.Id, out var i) ? i : throw new CloudFailure("invalid_request"); }

  private static string Group(string domain) => domain switch
  {
    "server" => "Servers", "api-key" => "API keys", "mcp" => "MCP servers", "ssh" => "Server keys", "task-connection" => "Task connections",
    "receiver" => "Receiver", "app" => "App passwords", _ => "Saved passwords"
  };
  private static long At(CloudSecretRecord? record) =>
    record?.Payload is CloudJson.Object o && o.Members.FirstOrDefault(m => m.Key == "at").Value is CloudJson.Number n ? (long)n.Value : 0;

  public async Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
  {
    var rows = new List<CloudContentsRow>();
    var found = new Dictionary<string, CloudDeleteItem>(StringComparer.Ordinal);
    foreach (var store in stores())
    {
      IReadOnlyList<CloudDeleteItem> listed;
      try { listed = await store.ItemsAsync(); } catch (CloudFailure) { continue; }
      foreach (var item in listed)
      {
        var id = "passwords|" + store.SourceId + "|" + item.Id;
        if (!found.TryAdd(id, item)) continue;
        rows.Add(new CloudContentsRow(id, Kind, CloudShelfWords.Plain(item.Name) ?? CloudShelfSealed.Noun(store.Domain), [Group(store.Domain)], At(store.LastExchanged(item.Id)),
          null, null, CloudItemState.InSync, IsSecret: true));
      }
    }
    if (secretFiles?.Invoke() is { } files)
    {
      IReadOnlyList<CloudProjectSecretFileTarget> listed = [];
      IReadOnlyDictionary<string, string> names = new Dictionary<string, string>();
      try { listed = files.DeleteListing(); names = files.ProjectNames(); } catch (CloudFailure) { }
      foreach (var target in listed)
      {
        var id = "passwords|" + CloudProjectSecretFilesStore.ItemKind + "|" + target.Item.Id;
        if (!found.TryAdd(id, target.Item)) continue;
        var project = CloudShelfWords.Plain(names.GetValueOrDefault(target.Item.Place ?? "")) ?? "A project";
        rows.Add(new CloudContentsRow(id, Kind, CloudShelfWords.Plain(CloudContentsText.Last(target.Item.Name)) ?? "File", [SecretFilesFolder, project], 0, null, null,
          CloudItemState.InSync, IsSecret: true));
      }
    }
    lock (items) { items.Clear(); foreach (var f in found) items[f.Key] = f.Value; }
    return rows;
  }
  public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) =>
    Task.FromResult<CloudOpenedItem?>(new(row.Name, row.ChangedAt, null, null, null, CloudMemoryContentsSource.Where(row), IsSecret: true));

  // ---- The removals, routed to the store that holds each item ----

  private IEnumerable<ICloudDeleteOwning> Owners() => stores().Cast<ICloudDeleteOwning>().Concat(secretFiles?.Invoke() is { } f ? [f] : []);
  private ICloudDeleteOwning? OwnerOf(CloudDeleteItem item) => item.Kind == CloudProjectSecretFilesStore.ItemKind
    ? secretFiles?.Invoke() : stores().FirstOrDefault(s => s.SourceId == item.Place);
  private async Task<List<T>> EachAsync<T>(IReadOnlyList<CloudDeleteItem> items, Func<ICloudDeleteOwning, IReadOnlyList<CloudDeleteItem>, Task<IEnumerable<T>>> act)
  {
    var made = new List<T>();
    foreach (var g in items.GroupBy(OwnerOf))
    {
      if (g.Key is null) throw new CloudFailure("invalid_request");
      made.AddRange(await act(g.Key, g.ToArray()));
    }
    return made;
  }
  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    var groups = await EachAsync(items, async (o, part) => (IEnumerable<CloudBinGroup>)[await o.DeleteItemsAsync(part, scope, by)]);
    var first = groups.FirstOrDefault();
    return new CloudBinGroup(by.Group, by.By, first?.MacName ?? by.MacName, by.Session, by.Agent, by.At, groups.SelectMany(g => g.Items).ToArray());
  }
  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to) =>
    await EachAsync(items, async (o, part) => (IEnumerable<CloudDeleteItem>)await o.BringBackAsync(part, to));
  public async Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync()
  {
    var made = new List<CloudNotHereItem>();
    foreach (var o in Owners()) made.AddRange(await o.NotHereAsync());
    return made;
  }
  public async Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync()
  {
    var made = new List<CloudBinGroup>();
    foreach (var o in Owners()) made.AddRange(await o.BinGroupsAsync());
    return CloudFileDeleteRecords.Merge(made);
  }
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
  {
    var made = new List<CloudDeleteItem>();
    foreach (var o in Owners())
      if ((await o.BinGroupsAsync()).Any(g => g.Id == group)) made.AddRange(await o.PutBackGroupAsync(group));
    return made;
  }
  public async Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items) =>
    await EachAsync(items, async (o, part) => { await o.DeleteForGoodAsync(part); return (IEnumerable<int>)[]; });
  /// Locked or without its sealed Bin, a store cannot honour a delete: the buttons are hidden for the whole kind then.
  public async Task<bool> CanDeleteEverywhereAsync()
  {
    var any = false;
    foreach (var o in Owners()) { any = true; if (!await o.CanDeleteEverywhereAsync()) return false; }
    return any;
  }
}

/// ONE call for the join: the contents reader with every source that exists registered (pass null for a part this PC
/// does not have yet; its kind then has no place).
public static class CloudContentsReader
{
  public static CloudContents Make(Func<bool> deleteRuleOpen, Func<CloudDeleteActor> person, Action<string>? log = null,
    IDeckMemoryCloudStore? memory = null, CloudMemoryAdapter? memoryAdapter = null, Func<IReadOnlyDictionary<string, string>>? memoryNames = null,
    Func<IReadOnlyList<CloudBootFilesPlace>>? bootPlaces = null, CloudBootFilesAdapter? bootFiles = null,
    CloudFolderOwner? cloudFolder = null, CloudArtifacts? artifacts = null,
    Func<CancellationToken, Task<IReadOnlyList<CloudSessionsRead.Row>>>? sessions = null, ICloudDeleteOwning? sessionsRemovals = null,
    Func<IReadOnlyList<CloudSetting>>? settings = null,
    CloudTasksOwner? tasks = null, CloudAgentsOwner? agents = null, CloudProjectsOwner? projects = null, Func<IReadOnlyDictionary<string, string>>? projectNames = null,
    Func<IReadOnlyList<CloudSecretsDeleteOwner>>? passwordStores = null, Func<CloudProjectSecretFilesStore?>? secretFiles = null)
  {
    var contents = new CloudContents(deleteRuleOpen, person) { Log = log };
    if (memory is not null) contents.Register(new CloudMemoryContentsSource(memory, memoryAdapter, memoryNames ?? projectNames));
    if (bootPlaces is not null) contents.Register(new CloudBootFilesContentsSource(bootPlaces, bootFiles));
    if (cloudFolder is not null) contents.Register(new CloudFolderContentsSource(cloudFolder));
    if (artifacts is not null) contents.Register(new CloudArtifactsContentsSource(artifacts));
    if (sessions is not null) contents.Register(new CloudSessionsContentsSource(sessions, sessionsRemovals));
    if (settings is not null) contents.Register(new CloudSettingsContentsSource(settings));
    if (tasks is not null) contents.Register(new CloudRecordsContentsSource(CloudContentsKind.Tasks, tasks, tasks, projectNames));
    if (agents is not null) contents.Register(new CloudRecordsContentsSource(CloudContentsKind.Agents, agents, agents, projectNames));
    if (projects is not null) contents.Register(new CloudRecordsContentsSource(CloudContentsKind.Projects, projects, projects, projectNames));
    if (passwordStores is not null || secretFiles is not null) contents.Register(new CloudPasswordsContentsSource(passwordStores ?? (() => []), secretFiles));
    return contents;
  }
}
