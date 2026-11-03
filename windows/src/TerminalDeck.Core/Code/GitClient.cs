namespace TerminalDeck.Core.Code;

public sealed class GitCommandException(string message) : InvalidOperationException(message);
public sealed record GitDiffResult(string Path, GitFileGroup Group, IReadOnlyList<GitDiffLine> Lines, int Hidden, string? Note);

// Source control through the system git (Git for Windows). Remote sign-in is
// left to git's own credential helper; nothing is stored here.
public sealed class GitClient(ICodeProcessRunner? runner = null)
{
  private readonly ICodeProcessRunner process = runner ?? new CodeProcessRunner();
  private static readonly TimeSpan Local = TimeSpan.FromSeconds(15);
  private static readonly TimeSpan Remote = TimeSpan.FromMinutes(3);

  private Task<CodeProcessResult> Git(string cwd, TimeSpan timeout, CancellationToken ct, params string[] args) => GitWithInput(cwd, timeout, ct, null, args);
  private Task<CodeProcessResult> GitWithInput(string cwd, TimeSpan timeout, CancellationToken ct, string? input, string[] args)
  {
    var all = new List<string> { "-c", "core.quotepath=off", "-c", "color.ui=never", "-C", cwd }; all.AddRange(args);
    return process.RunAsync("git", all, cwd, timeout, ct, input);
  }
  private async Task<string> Require(string verb, string cwd, TimeSpan timeout, CancellationToken ct, params string[] args)
  {
    var result = await Git(cwd, timeout, ct, args);
    if (!result.Ok) throw new GitCommandException(GitRules.Explain(verb, result));
    return result.Output;
  }
  private static string Folder(string cwd)
  {
    if (string.IsNullOrWhiteSpace(cwd)) throw new ArgumentException("Choose a project folder first.");
    return Path.TrimEndingDirectorySeparator(Path.GetFullPath(cwd));
  }

  public async Task<GitStatusResult> StatusAsync(string cwd, CancellationToken ct = default)
  {
    cwd = Folder(cwd);
    if (!Directory.Exists(cwd)) return new(null, cwd, GitUnavailableReason.NoSuchFolder, "The folder " + cwd + " no longer exists.");
    var top = await Git(cwd, Local, ct, "rev-parse", "--show-toplevel");
    if (top.Missing) return new(null, cwd, GitUnavailableReason.GitMissing, GitRules.MissingMessage);
    if (!top.Ok)
      return top.Error.Contains("not a git repository", StringComparison.OrdinalIgnoreCase)
        ? new(null, cwd, GitUnavailableReason.NotARepo, "This folder is not a git repository.", CanInit: true)
        : new(null, cwd, GitUnavailableReason.Error, GitRules.Explain("status", top));
    var root = Path.GetFullPath(top.Output.Trim());
    var status = await Git(cwd, Local, ct, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal");
    if (!status.Ok) return new(null, cwd, GitUnavailableReason.Error, GitRules.Explain("status", status));
    var repo = GitRules.ParseStatus(cwd, root, status.Output);
    var unstagedCounts = await Git(cwd, Local, ct, "diff", "--numstat", "-z");
    var stagedCounts = await Git(cwd, Local, ct, "diff", "--cached", "--numstat", "-z");
    repo = repo with
    {
      Unstaged = unstagedCounts.Ok ? GitRules.ApplyNumstat(repo.Unstaged, unstagedCounts.Output) : repo.Unstaged,
      Staged = stagedCounts.Ok ? GitRules.ApplyNumstat(repo.Staged, stagedCounts.Output) : repo.Staged
    };
    return new(repo, cwd);
  }

  public async Task<GitDiffResult> DiffAsync(string cwd, string path, GitFileGroup group, CancellationToken ct = default)
  {
    cwd = Folder(cwd); CheckPath(path);
    var root = (await Require("diff", cwd, Local, ct, "rev-parse", "--show-toplevel")).Trim();
    CodeProcessResult result = group switch
    {
      GitFileGroup.Staged => await Git(root, Local, ct, "diff", "--cached", "--", path),
      GitFileGroup.Untracked => await Git(root, Local, ct, "diff", "--no-index", "--", "/dev/null", path),
      _ => await Git(root, Local, ct, "diff", "--", path)
    };
    // --no-index answers 1 when the files differ.
    if (result.Missing || result.TimedOut || result.ExitCode > 1 || (group != GitFileGroup.Untracked && result.ExitCode != 0)) throw new GitCommandException(GitRules.Explain("diff", result));
    var lines = GitRules.ParseUnifiedDiff(result.Output);
    var hidden = Math.Max(0, lines.Count - GitRules.MaxDiffLines);
    return new(path, group, lines.Take(GitRules.MaxDiffLines).ToArray(), hidden, lines.Count == 0 ? GitRules.NoTextChange(group) : null);
  }

  private static void CheckPath(string path)
  {
    if (string.IsNullOrWhiteSpace(path) || path.Replace('\\', '/').Split('/').Contains("..") || Path.IsPathRooted(path) || path.StartsWith('-')) throw new ArgumentException("Choose a file inside this repository.");
  }
  private async Task<string> Root(string cwd, CancellationToken ct) => (await Require("status", Folder(cwd), Local, ct, "rev-parse", "--show-toplevel")).Trim();

  public async Task StageAsync(string cwd, IReadOnlyList<string> paths, CancellationToken ct = default)
  {
    if (paths.Count == 0) throw new ArgumentException("Choose the files to stage.");
    foreach (var path in paths) CheckPath(path);
    var root = await Root(cwd, ct);
    await Require("add", root, Local, ct, ["add", "-A", "--", .. paths]);
  }
  public async Task UnstageAsync(string cwd, IReadOnlyList<string> paths, CancellationToken ct = default)
  {
    if (paths.Count == 0) throw new ArgumentException("Choose the files to unstage.");
    foreach (var path in paths) CheckPath(path);
    var root = await Root(cwd, ct);
    var head = await Git(root, Local, ct, "rev-parse", "--verify", "-q", "HEAD");
    if (head.Ok) await Require("restore", root, Local, ct, ["restore", "--staged", "--", .. paths]);
    else await Require("rm", root, Local, ct, ["rm", "--cached", "-r", "-q", "--", .. paths]);
  }
  public async Task<string> CommitAsync(string cwd, string message, CancellationToken ct = default)
  {
    message = (message ?? "").Trim();
    if (message.Length == 0) throw new ArgumentException("Write a commit message first.");
    var root = await Root(cwd, ct);
    var result = await GitWithInput(root, Local, ct, message + "\n", ["commit", "-q", "-F", "-"]);
    if (!result.Ok) throw new GitCommandException(GitRules.Explain("commit", result));
    return (await Require("rev-parse", root, Local, ct, "rev-parse", "--short", "HEAD")).Trim();
  }
  public async Task<IReadOnlyList<GitBranchRef>> BranchesAsync(string cwd, CancellationToken ct = default) =>
    GitRules.ParseBranches(await Require("branch", Folder(cwd), Local, ct, "for-each-ref", "--sort=-committerdate", "--format=" + GitRules.BranchFormat, "refs/heads", "refs/remotes"));
  public async Task SwitchAsync(string cwd, string branch, bool create, CancellationToken ct = default)
  {
    branch = (branch ?? "").Trim();
    if (branch.Length == 0 || branch.StartsWith('-')) throw new ArgumentException("Choose a branch name.");
    cwd = Folder(cwd);
    var valid = await Git(cwd, Local, ct, "check-ref-format", "--branch", branch);
    if (!valid.Ok) throw new GitCommandException(valid.Missing ? GitRules.MissingMessage : "That is not a valid branch name.");
    await Require("switch", cwd, Local, ct, create ? ["switch", "-c", branch] : ["switch", branch]);
  }
  public async Task FetchAsync(string cwd, CancellationToken ct = default) => await Require("fetch", Folder(cwd), Remote, ct, "fetch", "--prune");
  public async Task PullAsync(string cwd, CancellationToken ct = default) => await Require("pull", Folder(cwd), Remote, ct, "pull", "--ff-only");
  public async Task PushAsync(string cwd, CancellationToken ct = default)
  {
    cwd = Folder(cwd);
    var status = await StatusAsync(cwd, ct);
    var branch = status.Repo?.Branch ?? throw new GitCommandException(GitRules.Unavailable(status).Message);
    if (branch.Detached || branch.Name is null) throw new GitCommandException("You are not on a branch. Switch to a branch before pushing.");
    if (branch.Upstream is null)
    {
      var remotes = (await Require("remote", cwd, Local, ct, "remote")).Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(r => r.Trim()).ToArray();
      var remote = remotes.Contains("origin") ? "origin" : remotes.FirstOrDefault() ?? throw new GitCommandException("This repository has no remote to push to. Add one (for example with git remote add origin <address>) and try again.");
      await Require("push", cwd, Remote, ct, "push", "-u", remote, branch.Name);
    }
    else await Require("push", cwd, Remote, ct, "push");
  }
  public async Task<IReadOnlyList<GitCommitInfo>> LogAsync(string cwd, int limit = 100, CancellationToken ct = default)
  {
    cwd = Folder(cwd);
    var result = await Git(cwd, Local, ct, "log", "-n", Math.Clamp(limit, 1, 500).ToString(System.Globalization.CultureInfo.InvariantCulture), "--pretty=format:" + GitRules.LogFormat);
    if (!result.Ok && result.Error.Contains("does not have any commits", StringComparison.OrdinalIgnoreCase)) return [];
    if (!result.Ok) throw new GitCommandException(GitRules.Explain("log", result));
    return GitRules.ParseLog(result.Output);
  }
  public async Task InitAsync(string cwd, CancellationToken ct = default) => await Require("init", Folder(cwd), Local, ct, "init");
}
