using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Remote;

// Extra host capabilities share the authenticated link and current access check.
// They never call the unrestricted desktop tool door on behalf of a device.
public interface IPhoneHostWorkspace
{
  void Bind(Func<string, JsonObject, CancellationToken, ValueTask> publish, Func<string, ApprovedDevice?> current) { }
  ValueTask DisconnectedAsync(string channel) => ValueTask.CompletedTask;
  IReadOnlyList<string> Capabilities { get; }
  bool Handles(string type);
  bool Permits(PhoneAccess access, string type);
  ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct);
}

public sealed class PhoneWorkspaceFeatures(Func<ApprovedDevice, IReadOnlyList<string>> folders,
  Func<ApprovedDevice, string, JsonElement, string?, CancellationToken, ValueTask<JsonObject>>? owner = null,
  GitClient? git = null) : IPhoneHostWorkspace
{
  private static readonly HashSet<string> Reads = ["folders.browse", "files.list", "files.read", "git.status", "git.diff"];
  private static readonly HashSet<string> Owner = ["usage.read", "account.read", "account.switch", "devices.list", "devices.revoke"];
  private readonly GitClient git = git ?? new();
  public IReadOnlyList<string> Capabilities => owner is null ? ["folders.pick", "files", "git", "git.write"] : ["folders.pick", "files", "git", "git.write", "usage", "account", "devices"];
  public bool Handles(string type) => Reads.Contains(type) || type is "git.commit" or "git.push" || owner is not null && Owner.Contains(type);
  public bool Permits(PhoneAccess access, string type) => access != PhoneAccess.Hoot && (Reads.Contains(type) || access == PhoneAccess.Full);
  private static readonly JsonSerializerOptions WireOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };

  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    if (!Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "This action needs Full control. Change this device's access on the PC.");
    if (Owner.Contains(type) && owner is not null) return [await owner(device, type, message, rid, ct)];
    var roots = folders(device);
    var requested = Text(message, "path", false) ?? (device.Access == PhoneAccess.Full ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : roots.FirstOrDefault());
    if (requested is null) throw new PhoneRefusal("unauthorized", "This PC does not share a folder with this device.");
    var path = PhoneWorkspacePaths.Require(requested, roots, device.Access == PhoneAccess.Full);
    if (type is "folders.browse" or "files.list") return [List(path, roots, device.Access == PhoneAccess.Full, type == "folders.browse", ct)];
    if (type == "files.read") return [await ReadAsync(path, message, ct)];
    if (type == "git.status") return [new() { ["t"] = "git.state", ["path"] = path, ["status"] = Status(await git.StatusAsync(path, ct)) }];
    if (type == "git.diff")
    {
      var file = Text(message, "file")!;
      _ = PhoneWorkspacePaths.Require(Path.GetFullPath(Path.Combine(path, file)), [path], false);
      var staged = Bool(message, "staged");
      var diff = await git.DiffAsync(path, file, staged ? GitFileGroup.Staged : Bool(message, "untracked") ? GitFileGroup.Untracked : GitFileGroup.Unstaged, ct);
      var patch = Cut(string.Join("\n", diff.Lines.Select(l => (l.Kind == GitDiffLineKind.Add ? "+" : l.Kind == GitDiffLineKind.Del ? "-" : l.Kind == GitDiffLineKind.Context ? " " : "") + l.Text)) + (diff.Hidden > 0 ? "\n[Open this change on the computer to read the rest.]" : ""));
      return [new() { ["t"] = "git.patch", ["path"] = path, ["file"] = file, ["staged"] = staged, ["patch"] = patch }];
    }
    if (type == "git.commit")
    {
      var text = Text(message, "message")!;
      var status = await git.StatusAsync(path, ct);
      if (status.Repo is not { } repo) throw new PhoneRefusal("unavailable", status.Message);
      if (repo.Conflicted.Count > 0) throw new PhoneRefusal("unavailable", "Resolve the conflicting files on the PC before committing.");
      var changes = repo.Unstaged.Concat(repo.Untracked).Select(f => f.Path).Distinct().ToArray();
      if (changes.Length > 0) await git.StageAsync(path, changes, ct);
      await git.CommitAsync(path, text, ct);
    }
    else if (type == "git.push") await git.PushAsync(path, ct);
    else throw new PhoneRefusal("bad-message", "unknown message type: " + type);
    return [new() { ["t"] = "git.done", ["path"] = path, ["action"] = type == "git.commit" ? "commit" : "push", ["ok"] = true,
      ["message"] = type == "git.commit" ? "Changes committed." : "Changes pushed.", ["status"] = Status(await git.StatusAsync(path, ct)) }];
  }

  private static JsonObject List(string path, IReadOnlyList<string> roots, bool full, bool foldersOnly, CancellationToken ct)
  {
    var dir = new DirectoryInfo(path);
    if (!dir.Exists) throw new PhoneRefusal("unavailable", "That folder is not on this PC any more.");
    var rows = new JsonArray();
    var options = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false, AttributesToSkip = FileAttributes.System };
    // Bound enumeration as well as the outgoing frame. A huge folder cannot stall every relay request.
    var entries = dir.EnumerateFileSystemInfos("*", options).Take(2001).OrderByDescending(i => i is DirectoryInfo).ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase);
    var bytes = 0;
    foreach (var item in entries)
    {
      ct.ThrowIfCancellationRequested();
      var directory = (item.Attributes & FileAttributes.Directory) != 0;
      if (foldersOnly && (!directory || item.Name.StartsWith('.'))) continue;
      var readable = true;
      try { _ = PhoneWorkspacePaths.Require(item.FullName, roots, full); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or PhoneRefusal) { readable = false; }
      var row = new JsonObject { ["name"] = item.Name, ["path"] = item.FullName, ["readable"] = readable };
      if (foldersOnly) row["granted"] = roots.Any(r => string.Equals(Path.TrimEndingDirectorySeparator(r), Path.TrimEndingDirectorySeparator(item.FullName), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal));
      else
      {
        row["directory"] = directory;
        if (!directory && item is FileInfo file && readable) { row["size"] = file.Length; row["at"] = new DateTimeOffset(file.LastWriteTimeUtc).ToUnixTimeMilliseconds(); }
      }
      bytes += Encoding.UTF8.GetByteCount(row.ToJsonString());
      if (bytes > 65_000 || rows.Count == 500) break;
      rows.Add(row);
    }
    string? parent = dir.Parent?.FullName;
    if (parent is not null) { try { _ = PhoneWorkspacePaths.Require(parent, roots, full); } catch (PhoneRefusal) { parent = null; } }
    return new() { ["t"] = foldersOnly ? "folders.entries" : "files.rows", ["path"] = path, ["parent"] = parent, ["entries"] = rows };
  }

  private static async Task<JsonObject> ReadAsync(string path, JsonElement message, CancellationToken ct)
  {
    var at = Number(message, "at", 0, 0, int.MaxValue);
    var limit = Number(message, "max", 12_000, 1, 12_000);
    await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
    if (at > file.Length) throw new PhoneRefusal("bad-message", "That file position is past the end.");
    file.Position = at;
    var data = new byte[limit]; var count = await file.ReadAsync(data, ct);
    var binary = FilesRules.LooksBinary(data.AsSpan(0, count));
    return new() { ["t"] = "files.text", ["path"] = path, ["at"] = at, ["text"] = binary ? "" : Encoding.UTF8.GetString(data, 0, count), ["binary"] = binary, ["truncated"] = file.Position < file.Length };
  }

  public static JsonObject Status(GitStatusResult result)
  {
    if (result.Repo is { } repo) { var node = (JsonObject)JsonSerializer.SerializeToNode(repo, WireOptions)!; node["repo"] = true; return node; }
    return new() { ["repo"] = false, ["cwd"] = result.Cwd, ["reason"] = result.Reason switch { GitUnavailableReason.NotARepo => "not-a-repo", GitUnavailableReason.NoSuchFolder => "no-such-folder", GitUnavailableReason.GitMissing => "git-missing", _ => "error" }, ["message"] = result.Message, ["canInit"] = result.CanInit };
  }
  public static string? Text(JsonElement value, string key, bool required = true)
  {
    if (!value.TryGetProperty(key, out var found) && !required) return null;
    if (found.ValueKind != JsonValueKind.String || found.GetString() is not { } text || text.Length == 0 || text.Length > 4096 || text.Any(char.IsControl))
      throw new PhoneRefusal("bad-message", "Choose a valid " + key + ".");
    return text;
  }
  private static bool Bool(JsonElement value, string key) => value.TryGetProperty(key, out var b) && b.ValueKind == JsonValueKind.True;
  private static int Number(JsonElement value, string key, int fallback, int min, int max) => !value.TryGetProperty(key, out var n) ? fallback : n.TryGetInt32(out var number) && number >= min && number <= max ? number : throw new PhoneRefusal("bad-message", "Invalid " + key + ".");
  private static string Cut(string text) { if (Encoding.UTF8.GetByteCount(text) <= 12_000) return text; return Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(text).AsSpan(0, 12_000)) + "\n[Open this change on the computer to read the rest.]"; }
}

public static class PhoneWorkspacePaths
{
  // Resolve every component so an intermediate Windows junction cannot escape a grant.
  public static string Resolve(string path)
  {
    if (!Path.IsPathFullyQualified(path) || path.IndexOf('\0') >= 0) throw new PhoneRefusal("bad-message", "Choose a folder by its full path.");
    var full = Path.GetFullPath(path);
    var volume = Path.GetPathRoot(full)!;
    var current = volume;
    foreach (var part in full[volume.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
    {
      current = Path.Combine(current, part);
      FileSystemInfo info = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
      if (info.LinkTarget is not null) current = info.ResolveLinkTarget(true)?.FullName ?? throw new PhoneRefusal("unauthorized", "This link cannot be followed safely.");
    }
    return Path.TrimEndingDirectorySeparator(current);
  }
  public static string Require(string path, IReadOnlyList<string> folders, bool unrestricted)
  {
    var resolved = Resolve(path);
    if (!unrestricted && !folders.Any(f => ProjectFiles.Inside(Resolve(f), resolved))) throw new PhoneRefusal("unauthorized", "This PC does not share that folder with this device.");
    return resolved;
  }
}
