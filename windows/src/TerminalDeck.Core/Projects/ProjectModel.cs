using System.Collections.Immutable;
using System.Text.Json;

namespace TerminalDeck.Core.Projects;

public sealed record ProjectAiChoice(string Use, string Provider, string? AccountId);
public sealed record ProjectSettings(ImmutableDictionary<string, JsonElement> Values, ImmutableArray<ProjectAiChoice> WhoUsesWhat)
{
  public static ProjectSettings Empty { get; } = new(ImmutableDictionary<string, JsonElement>.Empty, []);
  public string Text(string key) => Values.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";
  public bool Flag(string key) => Values.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.True;
}
public sealed record Project(string Id, string Name, ImmutableArray<string> Folders, string Icon = "folder", string Colour = "blue",
  string Logo = "", string? Lead = null, string LeadName = "", bool IsOpen = true, ProjectSettings? Settings = null)
{
  public string? HomeFolder => Folders.IsDefaultOrEmpty ? null : Folders[0];
  public ProjectSettings Preferences => Settings ?? ProjectSettings.Empty;
}
public sealed record ProjectDraft(string Id, string Name, ImmutableArray<string> Folders, string? Icon = null, string? Colour = null);
public sealed record ProjectSessionLink(string SessionId, string ProjectId);
public sealed record ProjectState(int Version, ImmutableArray<Project> Projects, string? ActiveProjectId, ImmutableArray<ProjectSessionLink> Sessions);
public sealed record ProjectSession(string Id, string Title, string Provider, string Folder, string Status, string? ProjectId = null, string? AgentId = null, string Mode = "terminal");
public sealed record ProjectSessionGroup(string ProjectId, string Name, string Logo, ImmutableArray<ProjectSession> Sessions);

public interface IProjects
{
  event Action? Changed;
  IReadOnlyList<Project> List();
  Project Get(string id);
  string? ActiveProjectId { get; }
  Project Create(string name, string homeFolder);
  string CreateFolder(string parent, string name);
  Project Save(ProjectDraft draft, Project? expected = null, bool createOnly = false);
  Project Rename(string id, string name, string expectedName);
  Project OpenFolder(string folder);
  Project SetOpen(string id, bool open);
  void Remove(string id);
  void SetRemovalGuard(string owner, Action<string> check);
  void RemoveEmpty(string id);
  void Select(string? id);
  Project SetLead(string id, string? lead, string name = "");
  Project SetPicture(string id, string? source);
  Project PatchSettings(string id, IReadOnlyDictionary<string, JsonElement> values);
  Project SetWhoUsesWhat(string id, IReadOnlyList<ProjectAiChoice> choices);
  string Resolve(string? projectId, string? folder);
  void BindSession(string sessionId, string projectId);
  IReadOnlyList<ProjectSessionGroup> GroupSessions(IEnumerable<ProjectSession> sessions);
  ProjectSetupScore Setup(string id, IEnumerable<ProjectSetupAgent> agents, string? card = null);
  string? PicturePath(string id);
}

public interface IProjectFolders
{
  string RequireFolder(string folder);
  string Create(string parent, string name) => throw new NotSupportedException("Folder creation is not connected on this host.");
  IReadOnlyList<ProjectFolder> Browse(string folder, bool showHidden);
}
public sealed record ProjectFolder(string Name, string Path, bool Repository);
public interface IProjectPictures
{
  string Adopt(string projectId, string source);
  string? PathFor(string name);
  void Discard(string name);
}

public static class ProjectIdentity
{
  public const string IndependentId = "independent";
  public static Project Independent { get; } = new(IndependentId, "Independent", [], Colour: "graphite");
  public static readonly string[] Colours = ["blue", "purple", "pink", "orange", "yellow", "green", "teal", "graphite"];
  public static bool ValidId(string id) => id.Length is > 0 and <= 128 && char.IsAsciiLetterOrDigit(id[0]) && id.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-');
  public static string NewId(string name, IEnumerable<string> taken)
  {
    var words = name.ToLowerInvariant().Select(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' ? c : '-');
    var basis = string.Join('-', new string(words.ToArray()).Split('-', StringSplitOptions.RemoveEmptyEntries));
    basis = basis.Length == 0 ? "project" : basis[..Math.Min(100, basis.Length)];
    var used = taken.ToHashSet(StringComparer.Ordinal); used.Add(IndependentId);
    var id = basis; for (var n = 2; used.Contains(id); n++) id = basis + "-" + n;
    return id;
  }
}

// Folder matching also handles Windows paths when the pure Core runs on a Mac.
public static class ProjectPaths
{
  private static bool Windows(string path) => path.Length > 2 && char.IsAsciiLetter(path[0]) && path[1] == ':' || path.StartsWith("\\\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal);
  public static string Normalize(string path)
  {
    if (string.IsNullOrWhiteSpace(path) || path.Any(char.IsControl)) throw new ArgumentException("Choose an absolute home folder.");
    if (!Windows(path))
    {
      if (!Path.IsPathFullyQualified(path)) throw new ArgumentException("Choose an absolute home folder.");
      return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    }
    var clean = path.Replace('\\', '/');
    var unc = clean.StartsWith("//", StringComparison.Ordinal);
    if (!unc && (clean.Length < 3 || clean[2] != '/')) throw new ArgumentException("Choose an absolute home folder.");
    var parts = new List<string>();
    foreach (var part in clean.Split('/', StringSplitOptions.RemoveEmptyEntries))
    {
      if (part == ".") continue;
      if (part == "..") { if (parts.Count > (unc ? 2 : 1)) parts.RemoveAt(parts.Count - 1); continue; }
      parts.Add(part);
    }
    if (unc && parts.Count < 2) throw new ArgumentException("Choose a complete network folder.");
    return (unc ? "//" : "") + string.Join('/', parts) + (!unc && parts.Count == 1 ? "/" : "");
  }
  public static bool Equal(string first, string second) => string.Equals(Normalize(first), Normalize(second), Comparison(first));
  public static bool Contains(string root, string path)
  {
    root = Normalize(root); path = Normalize(path);
    return string.Equals(root, path, Comparison(root)) || path.StartsWith(root.TrimEnd('/') + "/", Comparison(root));
  }
  private static StringComparison Comparison(string path) => Windows(path) || path.StartsWith("//", StringComparison.Ordinal) ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}
