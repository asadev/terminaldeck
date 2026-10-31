using System.Text.Json;

namespace TerminalDeck.Core.Code;

// GitHub, read-only, through the person's own gh CLI sign-in (or GH_TOKEN).
// This app keeps no GitHub secret of its own.
public sealed class GitHubClient(ICodeProcessRunner? runner = null, Func<string, string?>? environment = null)
{
  private readonly ICodeProcessRunner process = runner ?? new CodeProcessRunner();
  private readonly Func<string, string?> env = environment ?? Environment.GetEnvironmentVariable;
  private static readonly TimeSpan Limit = TimeSpan.FromSeconds(30);
  public const int ListLimit = 30;
  // Test and scratch copies must never read the person's real GitHub login: they get
  // a private gh configuration folder under their own data root and no inherited token.
  // Only the real installed copy uses the person's own gh sign-in (like the Default AI login).
  public static GitHubClient ForCopy(string dataRoot, bool realCopy) => realCopy ? new() :
    new(new CodeProcessRunner(new Dictionary<string, string?> { ["GH_CONFIG_DIR"] = Path.Combine(dataRoot, "github"), ["GH_TOKEN"] = null, ["GITHUB_TOKEN"] = null }), name => name is "GH_TOKEN" or "GITHUB_TOKEN" ? null : Environment.GetEnvironmentVariable(name));
  public static bool IsRealCopy(string dataRoot, string appDirectory, string userProfile) =>
    TerminalDeck.Core.Storage.StableChannel.IsStable(appDirectory) && string.Equals(Path.GetFullPath(dataRoot).TrimEnd('\\', '/'), TerminalDeck.Core.Storage.StableChannel.Root(userProfile).DirectoryPath.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
  public const int RepoLimit = 100;

  private static string Folder(string? cwd) => string.IsNullOrWhiteSpace(cwd) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : Path.GetFullPath(cwd);
  private async Task<string> Gh(string? cwd, CancellationToken ct, params string[] args)
  {
    var folder = Folder(cwd);
    if (!Directory.Exists(folder)) throw new GitHubException(new("no-such-folder", "That folder no longer exists."));
    var result = await process.RunAsync("gh", args, folder, Limit, ct);
    if (!result.Ok) throw new GitHubException(GitHubRules.Classify(result));
    return result.Output;
  }

  public async Task<GitHubAuthState> AuthAsync(CancellationToken ct = default)
  {
    var source = env("GH_TOKEN") is { Length: > 0 } || env("GITHUB_TOKEN") is { Length: > 0 } ? "environment" : "gh-cli";
    try
    {
      var json = await Gh(null, ct, "api", "user");
      using var doc = JsonDocument.Parse(json); var row = doc.RootElement;
      string? Text(string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
      return new(true, true, Text("login"), Text("name"), Text("html_url"), source, "github.com", null);
    }
    catch (GitHubException ex) { return new(false, ex.Failure.Kind != "gh-missing", null, null, null, "none", "github.com", ex.Failure); }
    catch (JsonException) { return new(false, true, null, null, null, "none", "github.com", new("error", "GitHub answered with something unreadable. Try again.")); }
  }
  public async Task<GitHubRepoRef> RepoAsync(string cwd, CancellationToken ct = default) =>
    GitHubRules.ParseRepoView(await Gh(cwd, ct, "repo", "view", "--json", "nameWithOwner,url,defaultBranchRef,isPrivate"));
  public async Task<IReadOnlyList<GitHubRepoSummary>> ReposAsync(CancellationToken ct = default) =>
    GitHubRules.ParseRepos(await Gh(null, ct, "repo", "list", "--limit", RepoLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), "--json", "nameWithOwner,name,url,isPrivate,isFork,isArchived,description,primaryLanguage,pushedAt,defaultBranchRef"));
  public async Task<IReadOnlyList<GitHubPull>> PullsAsync(string cwd, CancellationToken ct = default) =>
    GitHubRules.ParsePulls(await Gh(cwd, ct, "pr", "list", "--state", "open", "--limit", ListLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), "--json", "number,title,url,author,updatedAt,reviewDecision,labels,isDraft,state,additions,deletions,isCrossRepository,statusCheckRollup"));
  public async Task<IReadOnlyList<GitHubIssue>> IssuesAsync(string cwd, CancellationToken ct = default) =>
    GitHubRules.ParseIssues(await Gh(cwd, ct, "issue", "list", "--state", "open", "--limit", ListLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), "--json", "number,title,url,author,updatedAt,labels,assignees,state"));
  public async Task<IReadOnlyList<GitHubRun>> ChecksAsync(string cwd, string? branch, CancellationToken ct = default)
  {
    var args = new List<string> { "run", "list", "--limit", "10", "--json", "name,workflowName,status,conclusion,url,headBranch,createdAt" };
    if (branch is { Length: > 0 }) { args.Add("--branch"); args.Add(branch); }
    return GitHubRules.ParseRuns(await Gh(cwd, ct, [.. args]));
  }
}
