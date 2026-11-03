using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Code;

// files.*, git.* and github.* for every AI. Reads run freely; changes go
// through the door's normal approval (Act / Alter), same as the other tools.
public sealed class CodeMcp(ProjectFiles files, GitClient git, GitHubClient github)
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };
  private static readonly object Text = new { type = "string", maxLength = 4096 };
  private static readonly object Cwd = new { type = "string", maxLength = 4096, description = "An open project folder, or a session's folder." };
  private static readonly object Boolean = new { type = "boolean" };
  public static IReadOnlyList<McpToolSpec> Specs { get; } = MakeSpecs();

  private static IReadOnlyList<McpToolSpec> MakeSpecs()
  {
    var specs = new List<McpToolSpec>();
    void Add(string id, McpTier tier, Dictionary<string, object> fields, params string[] required) => specs.Add(new(id, id.Replace('.', '_'), tier,
      JsonSerializer.SerializeToElement(new { type = "object", properties = fields, required, additionalProperties = false })));
    Add("files.list", McpTier.Read, new() { ["cwd"] = Cwd, ["path"] = Text, ["showIgnored"] = Boolean }, "cwd");
    Add("files.read", McpTier.Read, new() { ["cwd"] = Cwd, ["path"] = Text }, "cwd", "path");
    Add("files.search", McpTier.Read, new() { ["cwd"] = Cwd, ["query"] = Text, ["showIgnored"] = Boolean }, "cwd", "query");
    Add("git.status", McpTier.Read, new() { ["cwd"] = Cwd }, "cwd");
    Add("git.diff", McpTier.Read, new() { ["cwd"] = Cwd, ["path"] = Text, ["group"] = new { type = "string", @enum = new[] { "staged", "unstaged", "untracked", "conflicted" } } }, "cwd", "path");
    Add("git.log", McpTier.Read, new() { ["cwd"] = Cwd, ["limit"] = new { type = "integer", minimum = 1, maximum = 500 } }, "cwd");
    Add("git.stage", McpTier.Act, new() { ["cwd"] = Cwd, ["paths"] = new { type = "array", items = Text, maxItems = 500 }, ["unstage"] = Boolean }, "cwd", "paths");
    Add("git.commit", McpTier.Alter, new() { ["cwd"] = Cwd, ["message"] = new { type = "string", maxLength = 20000 } }, "cwd", "message");
    Add("git.branch", McpTier.Read, new() { ["cwd"] = Cwd, ["action"] = new { type = "string", @enum = new[] { "list", "switch", "create" } }, ["name"] = Text }, "cwd");
    Add("git.fetch", McpTier.Act, new() { ["cwd"] = Cwd }, "cwd");
    Add("git.pull", McpTier.Act, new() { ["cwd"] = Cwd }, "cwd");
    Add("git.push", McpTier.Alter, new() { ["cwd"] = Cwd }, "cwd");
    Add("github.status", McpTier.Read, []);
    Add("github.repos", McpTier.Read, new() { ["query"] = Text });
    Add("github.prs", McpTier.Read, new() { ["cwd"] = Cwd }, "cwd");
    Add("github.issues", McpTier.Read, new() { ["cwd"] = Cwd }, "cwd");
    Add("github.checks", McpTier.Read, new() { ["cwd"] = Cwd, ["branch"] = Text }, "cwd");
    return specs;
  }

  public static McpTier Tier(McpToolSpec spec, JsonElement arguments) => spec.Id switch
  {
    "git.branch" => arguments.TryGetProperty("action", out var action) && action.GetString() is "switch" or "create" ? McpTier.Act : McpTier.Read,
    _ => spec.Tier
  };

  // A grant names exact folders; a subfolder of a granted folder is inside it.
  public static string RequireFolder(McpCallContext context, string cwd)
  {
    if (string.IsNullOrWhiteSpace(cwd)) throw new McpRefusal("Choose a value for cwd.");
    var folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(cwd));
    if (context.Has("folders", cwd) || context.Has("folders", folder)) return folder;
    if (context.Grant.Resources.Any(r => r.StartsWith("folders:", StringComparison.Ordinal) && r.Length > 8 && CodeWorkspace.Within(Path.GetFullPath(r[8..]), folder))) return folder;
    throw new McpRefusal("That folder is outside this caller's permission.");
  }

  public void Register(McpDoor door)
  {
    if (!McpCatalogue.Load().Any(s => s.Id == Specs[0].Id)) return;
    foreach (var spec in Specs) { var id = spec.Id; door.Register(id, (context, args, ct) => CallAsync(id, context, args, ct)); }
  }

  private static JsonElement Value(object value) => JsonSerializer.SerializeToElement(value, Json);
  private static string? S(JsonElement args, string key) => args.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
  private static bool B(JsonElement args, string key) => args.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.True;

  public async ValueTask<JsonElement> CallAsync(string id, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    try
    {
      var cwd = S(args, "cwd") is { } given ? RequireFolder(context, given) : null;
      if (Specs.Single(s => s.Id == id).Tier != McpTier.Read || Tier(Specs.Single(s => s.Id == id), args) != McpTier.Read) await context.EnsureCurrentAsync(ct);
      switch (id)
      {
        case "files.list": return Value(await files.ListAsync(cwd!, S(args, "path") ?? "", B(args, "showIgnored"), ct));
        case "files.read": return Value(await files.ReadAsync(cwd!, DeckCoreTools.Required(args, "path"), ct));
        case "files.search": return Value(new { matches = await files.SearchAsync(cwd!, DeckCoreTools.Required(args, "query"), B(args, "showIgnored"), ct) });
        case "git.status":
          var status = await git.StatusAsync(cwd!, ct);
          return status.Repo is { } repo ? Value(new { repo = true, repo.Root, branch = repo.Branch, repo.Staged, repo.Unstaged, repo.Untracked, repo.Conflicted, repo.Clean })
            : Value(new { repo = false, reason = status.Reason, status.Message, status.CanInit });
        case "git.diff":
          var group = S(args, "group") switch { "staged" => GitFileGroup.Staged, "untracked" => GitFileGroup.Untracked, "conflicted" => GitFileGroup.Conflicted, _ => GitFileGroup.Unstaged };
          var diff = await git.DiffAsync(cwd!, DeckCoreTools.Required(args, "path"), group, ct);
          return Value(new { diff.Path, diff.Group, text = string.Join("\n", diff.Lines.Select(l => (l.Kind switch { GitDiffLineKind.Add => "+", GitDiffLineKind.Del => "-", GitDiffLineKind.Context => " ", _ => "" }) + l.Text)), diff.Hidden, diff.Note });
        case "git.log": return Value(new { commits = await git.LogAsync(cwd!, args.TryGetProperty("limit", out var limit) ? limit.GetInt32() : 50, ct) });
        case "git.stage":
          var paths = args.GetProperty("paths").EnumerateArray().Select(p => p.GetString() ?? "").ToArray();
          if (B(args, "unstage")) await git.UnstageAsync(cwd!, paths, ct); else await git.StageAsync(cwd!, paths, ct);
          return Value(new { done = true });
        case "git.commit": return Value(new { commit = await git.CommitAsync(cwd!, DeckCoreTools.Required(args, "message"), ct) });
        case "git.branch":
          var action = S(args, "action") ?? "list";
          if (action == "list") return Value(new { branches = await git.BranchesAsync(cwd!, ct) });
          await git.SwitchAsync(cwd!, DeckCoreTools.Required(args, "name"), action == "create", ct); return Value(new { done = true });
        case "git.fetch": await git.FetchAsync(cwd!, ct); return Value(new { done = true });
        case "git.pull": await git.PullAsync(cwd!, ct); return Value(new { done = true });
        case "git.push": await git.PushAsync(cwd!, ct); return Value(new { done = true });
        case "github.status": return Value(await github.AuthAsync(ct));
        case "github.repos": return Value(new { repos = GitHubRules.FilterRepos(await github.ReposAsync(ct), S(args, "query") ?? "") });
        case "github.prs": return Value(new { pulls = await github.PullsAsync(cwd!, ct) });
        case "github.issues": return Value(new { issues = await github.IssuesAsync(cwd!, ct) });
        case "github.checks": return Value(new { runs = await github.ChecksAsync(cwd!, S(args, "branch"), ct) });
        default: throw new McpRefusal("That tool is not available.");
      }
    }
    catch (GitHubException ex) { throw new McpRefusal(GitHubRules.Explanation(ex.Failure)); }
    catch (Exception ex) when (ex is GitCommandException or ArgumentException or IOException or UnauthorizedAccessException) { throw new McpRefusal(ex.Message); }
  }
}
