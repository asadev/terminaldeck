using System.Collections.Immutable;
using System.Diagnostics;
using System.Text.Json;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Tests.Mcp;

namespace TerminalDeck.Core.Tests.Code;

public sealed class CodeRulesTests
{
  [Fact]
  public void PorcelainV2SplitsGroupsBranchRenameAndConflict()
  {
    var text = string.Join('\0',
      "# branch.oid 1234567890abcdef", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
      "1 MM N... 100644 100644 100644 aaa bbb src/a.ts",
      "2 R. N... 100644 100644 100644 aaa bbb R100 docs/new.md", "docs/old.md",
      "u UU N... 100644 100644 100644 100644 a b c both.txt",
      "? notes/") + "\0";
    var status = GitRules.ParseStatus("/r", "/r", text);
    Assert.Equal("main", status.Branch.Label); Assert.Equal(2, status.Branch.Ahead); Assert.Equal(1, status.Branch.Behind); Assert.Equal("origin/main", status.Branch.Upstream);
    Assert.Equal(["src/a.ts", "docs/new.md"], status.Staged.Select(f => f.Path));
    Assert.Equal("docs/old.md", status.Staged[1].OrigPath); Assert.Equal(GitChangeKind.Renamed, status.Staged[1].Kind);
    Assert.Equal("src/a.ts", Assert.Single(status.Unstaged).Path);
    Assert.Equal("both.txt", Assert.Single(status.Conflicted).Path);
    Assert.Equal("notes/", Assert.Single(status.Untracked).Path);
    Assert.Equal(["Conflicts", "Staged", "Changes", "Untracked"], GitRules.Groups(status).Select(g => g.Label));
    Assert.Equal("both.txt", GitRules.FirstChoice(GitRules.Groups(status)));
    Assert.Contains("folder git has not looked inside", GitRules.NoDiffReason(status.Untracked[0]));
  }
  [Fact]
  public void DetachedBranchAndNumstatCountsAndBinary()
  {
    var status = GitRules.ParseStatus("/r", "/r", "# branch.oid abcdef1234\0# branch.head (detached)\0");
    Assert.Equal("detached at abcdef1", status.Branch.Label); Assert.True(status.Clean);
    var files = new[] { new GitFile("a.txt", GitFileGroup.Unstaged, GitChangeKind.Modified), new GitFile("b.png", GitFileGroup.Unstaged, GitChangeKind.Modified), new GitFile("new.md", GitFileGroup.Staged, GitChangeKind.Renamed, "R.", "old.md") };
    var counted = GitRules.ApplyNumstat(files, "3\t1\ta.txt\0-\t-\tb.png\0" + "0\t0\t\0old.md\0new.md\0");
    Assert.Equal((3, 1), (counted[0].Insertions!.Value, counted[0].Deletions!.Value)); Assert.True(counted[1].Binary); Assert.Equal(0, counted[2].Insertions);
    Assert.Equal("Modified · not staged yet · +3 −1", GitRules.DiffMeta(counted[0], GitFileGroup.Unstaged));
    Assert.Equal("Modified · not staged yet · binary", GitRules.DiffMeta(counted[1], GitFileGroup.Unstaged));
  }
  [Fact]
  public void UnifiedDiffKeepsHeadersAsMetaAndDashLinesInsideHunks()
  {
    var lines = GitRules.ParseUnifiedDiff("diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n--- removed dashes\n+++ added plus\n same\n");
    Assert.Equal([GitDiffLineKind.Meta, GitDiffLineKind.Meta, GitDiffLineKind.Meta, GitDiffLineKind.Meta, GitDiffLineKind.Hunk, GitDiffLineKind.Del, GitDiffLineKind.Add, GitDiffLineKind.Context], lines.Select(l => l.Kind));
    Assert.Equal("-- removed dashes", lines[5].Text);
  }
  [Fact]
  public void LogBranchesAndPlainErrors()
  {
    var log = GitRules.ParseLog("abc\u001fa\u001fAsad\u001f2026-10-30T06:00:00+04:00\u001fFirst\u001e\nbcd\u001fb\u001fAsad\u001f2026-10-30T07:00:00+04:00\u001fSecond\u001e");
    Assert.Equal(["First", "Second"], log.Select(c => c.Subject));
    var branches = GitRules.ParseBranches("refs/heads/main\u001f*\u001forigin/main\nrefs/heads/dev\u001f \u001f\nrefs/remotes/origin/HEAD\u001f \u001f\nrefs/remotes/origin/main\u001f \u001f\n");
    Assert.Equal(["main", "dev", "origin/main"], branches.Select(b => b.Name)); Assert.True(branches[0].Current); Assert.True(branches[2].Remote);
    Assert.Equal(GitRules.MissingMessage, GitRules.Explain("push", new(-1, "", "", Missing: true)));
    Assert.Contains("could not sign in", GitRules.Explain("push", new(128, "", "fatal: Authentication failed for 'https://github.com/x/y'")));
    Assert.Contains("Pull first", GitRules.Explain("push", new(1, "", " ! [rejected] main -> main (fetch first)")));
    Assert.Contains("both changed", GitRules.Explain("pull", new(128, "", "fatal: Not possible to fast-forward, aborting.")));
    Assert.Contains("took too long", GitRules.Explain("fetch", new(-1, "", "", TimedOut: true)));
  }
  [Fact]
  public void FileTreeRowsAndKeyboardFollowTheMac()
  {
    var tree = new FileTreeState();
    Assert.Equal(TreeRootKind.Loading, tree.RootState.Kind);
    tree.Loaded("", new("", [new("src", "src", true), new("README.md", "README.md", false)]));
    Assert.Equal("src", tree.Focused);
    Assert.Equal(FileTreeState.EffectKind.Toggle, tree.Effect(FileTreeState.Key.Right).Kind);
    tree.LoadStarted("src"); tree.Loaded("src", new("src", [new("a.ts", "src/a.ts", false)]));
    Assert.Equal(["src", "src/a.ts", "README.md"], tree.Rows.Select(r => r.Entry.RelPath));
    tree.Focused = "src/a.ts";
    Assert.Equal(new FileTreeState.KeyEffect(FileTreeState.EffectKind.Focus, "src"), tree.Effect(FileTreeState.Key.Left));
    Assert.Equal(FileTreeState.Toggle.Collapse, tree.ToggleFor(tree.Rows[0].Entry));
    tree.Failed("", "denied"); Assert.Equal(FilesPageLayout.TreeOnly, FilesRules.Layout(tree.RootState));
    Assert.Equal("Binary file — 2.0 KB. Nothing readable to show.", FilesRules.BinaryLine(2048));
    Assert.Equal("Nothing in demo that your .gitignore does not exclude.", FilesRules.BlankReason("demo", false));
  }
  [Fact]
  public void GitHubFailuresPullsAndChecks()
  {
    Assert.Equal("gh-missing", GitHubRules.Classify(new(-1, "", "", Missing: true)).Kind);
    var login = GitHubRules.Classify(new(4, "", "To get started with GitHub CLI, please run:  gh auth login"));
    Assert.Equal("not-authenticated", login.Kind); Assert.Equal("This computer is not signed in to GitHub. Run gh auth login in a terminal, then refresh.", GitHubRules.Explanation(login));
    Assert.Equal("no-github-remote", GitHubRules.Classify(new(1, "", "none of the git remotes configured for this repository point to a known GitHub host")).Kind);
    Assert.Equal("network-down", GitHubRules.Classify(new(1, "", "error connecting to api.github.com")).Kind);
    var pulls = GitHubRules.ParsePulls("""[{"number":7,"title":"Fix","url":"https://github.com/o/r/pull/7","author":{"login":"asad"},"updatedAt":"2026-10-30T00:00:00Z","reviewDecision":"APPROVED","labels":[{"name":"bug","color":"d73a4a"}],"isDraft":false,"state":"OPEN","additions":3,"deletions":1,"isCrossRepository":false,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS","conclusion":""}]}]""");
    var pull = Assert.Single(pulls); Assert.Equal("pending", pull.Checks); Assert.Equal("asad", pull.Author); Assert.Equal("Approved", GitHubRules.ReviewLabel(pull.Review));
    var issues = GitHubRules.ParseIssues("""[{"number":3,"title":"Bug","url":"u","author":{"login":"a"},"updatedAt":"","labels":[],"assignees":[{"login":"b"}],"state":"OPEN"}]""");
    Assert.Equal(["b"], Assert.Single(issues).Assignees);
    Assert.Equal("2h", GitHubRules.FormatAge("2026-10-30T04:00:00Z", DateTimeOffset.Parse("2026-10-30T06:30:00Z")));
    Assert.Equal("30+", GitHubRules.CountLabel(30, 30));
    Assert.False(GitHubRules.SafeWebUrl("javascript:alert(1)"));
  }
  [Fact]
  public void WorkspaceListsEveryOpenProjectAndIndependentFoldersAndFollowsTheSession()
  {
    var a = Path.Combine(Path.GetTempPath(), "td-code-a"); var b = Path.Combine(Path.GetTempPath(), "td-code-b"); var loose = Path.Combine(Path.GetTempPath(), "td-code-loose");
    var projects = new[]
    {
      new Project("p1", "Alpha", [a]), new Project("p2", "Beta", [b]), new Project("p3", "Closed", [Path.Combine(Path.GetTempPath(), "closed")], IsOpen: false),
      ProjectIdentity.Independent
    };
    var roots = CodeWorkspace.Roots(projects, [new(ProjectIdentity.IndependentId, loose), new("p1", Path.Combine(a, "src")), new(null, Path.Combine(b, "sub"))]);
    Assert.Equal(["Alpha", "Beta", "td-code-loose"], roots.Select(r => r.Name));
    Assert.True(roots[2].Independent);
    Assert.Equal("Beta", CodeWorkspace.Current(roots, "p1", Path.Combine(b, "sub"))!.Name);
    Assert.Equal("Alpha", CodeWorkspace.Current(roots, "p1", null)!.Name);
    Assert.Equal("td-code-loose", CodeWorkspace.Current(roots, null, loose)!.Name);
  }
}

public sealed class CodeLiveTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-code-" + Guid.NewGuid().ToString("N"));
  public CodeLiveTests() => Directory.CreateDirectory(root);
  public void Dispose() { try { foreach (var f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(f, FileAttributes.Normal); Directory.Delete(root, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
  private void Git(params string[] args)
  {
    var start = new ProcessStartInfo("git") { WorkingDirectory = root, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var a in args) start.ArgumentList.Add(a);
    using var p = Process.Start(start)!; p.WaitForExit(); Assert.True(p.ExitCode == 0, p.StandardError.ReadToEnd());
  }

  [Fact]
  public async Task FilesRespectGitignoreLinksAndContainment()
  {
    Git("init", "-q");
    File.WriteAllText(Path.Combine(root, ".gitignore"), "build/\n*.log\n");
    Directory.CreateDirectory(Path.Combine(root, "build")); Directory.CreateDirectory(Path.Combine(root, "src"));
    File.WriteAllText(Path.Combine(root, "src", "app.ts"), "const a = 1;\n"); File.WriteAllText(Path.Combine(root, "debug.log"), "x");
    File.WriteAllText(Path.Combine(root, "README.md"), "# Hi\n"); File.WriteAllBytes(Path.Combine(root, "logo.bin"), [1, 0, 2]);
    if (!OperatingSystem.IsWindows()) File.CreateSymbolicLink(Path.Combine(root, "outside"), Path.GetTempPath());
    var files = new ProjectFiles();
    var hidden = await files.ListAsync(root, "", showIgnored: false);
    Assert.DoesNotContain(hidden.Entries, e => e.Name is "build" or "debug.log" or ".git");
    Assert.True(hidden.Entries.ToList().FindIndex(e => e.Name == "src") < hidden.Entries.ToList().FindIndex(e => e.Name == "README.md")); Assert.Equal("README.md", hidden.DefaultFile);
    var all = await files.ListAsync(root, "", showIgnored: true);
    Assert.True(all.Entries.Single(e => e.Name == "build").Ignored);
    if (!OperatingSystem.IsWindows()) Assert.True(all.Entries.Single(e => e.Name == "outside").Blocked);
    Assert.Equal(FileReadKind.Text, (await files.ReadAsync(root, "src/app.ts")).Kind);
    Assert.Equal(FileReadKind.Binary, (await files.ReadAsync(root, "logo.bin")).Kind);
    await Assert.ThrowsAsync<ArgumentException>(() => files.ReadAsync(root, "../etc/passwd"));
    Assert.Equal(["src/app.ts"], (await files.SearchAsync(root, "app", false)).Select(m => m.RelPath));
    Assert.Empty(await files.SearchAsync(root, "debug", false));
  }

  [Fact]
  public async Task GitStageCommitBranchAndLogThroughSystemGit()
  {
    Git("init", "-q", "-b", "main"); Git("config", "user.name", "Test"); Git("config", "user.email", "t@example.invalid"); Git("config", "commit.gpgsign", "false");
    var git = new GitClient();
    File.WriteAllText(Path.Combine(root, "a.txt"), "one\n");
    var status = (await git.StatusAsync(root)).Repo!;
    Assert.Equal("a.txt", Assert.Single(status.Untracked).Path);
    await git.StageAsync(root, ["a.txt"]);
    Assert.Equal("a.txt", Assert.Single((await git.StatusAsync(root)).Repo!.Staged).Path);
    await git.UnstageAsync(root, ["a.txt"]);
    Assert.Single((await git.StatusAsync(root)).Repo!.Untracked);
    await Assert.ThrowsAsync<GitCommandException>(() => git.CommitAsync(root, "nothing staged"));
    await git.StageAsync(root, ["a.txt"]);
    var commit = await git.CommitAsync(root, "First commit");
    Assert.False(string.IsNullOrEmpty(commit));
    File.WriteAllText(Path.Combine(root, "a.txt"), "one\ntwo\n");
    var diff = await git.DiffAsync(root, "a.txt", GitFileGroup.Unstaged);
    Assert.Contains(diff.Lines, l => l.Kind == GitDiffLineKind.Add && l.Text == "two");
    File.WriteAllText(Path.Combine(root, "new.txt"), "fresh\n");
    Assert.Contains((await git.DiffAsync(root, "new.txt", GitFileGroup.Untracked)).Lines, l => l.Kind == GitDiffLineKind.Add && l.Text == "fresh");
    await git.StageAsync(root, ["a.txt"]); await git.CommitAsync(root, "Second");
    await git.SwitchAsync(root, "feature", create: true);
    Assert.Equal("feature", (await git.StatusAsync(root)).Repo!.Branch.Name);
    await Assert.ThrowsAsync<GitCommandException>(() => git.SwitchAsync(root, "bad..name", create: true));
    Assert.Contains(await git.BranchesAsync(root), b => b.Name == "main" && !b.Current);
    Assert.Equal(["Second", "First commit"], (await git.LogAsync(root)).Select(c => c.Subject));
    var push = await Assert.ThrowsAsync<GitCommandException>(() => git.PushAsync(root));
    Assert.Contains("no remote", push.Message);
  }

  [Fact]
  public async Task NotARepoOffersInit()
  {
    var result = await new GitClient().StatusAsync(root);
    Assert.Null(result.Repo); Assert.True(result.CanInit); Assert.Equal("Nothing to track here", GitRules.Unavailable(result).Title);
  }

  [Fact]
  public async Task McpReadsRunWithinGrantedFoldersAndChangesAskFirst()
  {
    Git("init", "-q", "-b", "main"); Git("config", "user.name", "Test"); Git("config", "user.email", "t@example.invalid");
    File.WriteAllText(Path.Combine(root, "a.txt"), "x\n");
    var catalogue = McpCatalogue.Load();
    foreach (var spec in CodeMcp.Specs) Assert.Single(catalogue, s => s.Id == spec.Id);
    Assert.Equal(catalogue.Count, catalogue.Select(s => s.Wire).Distinct().Count());
    var permission = new FakePermission();
    var door = new McpDoor(permission);
    new CodeMcp(new ProjectFiles(), new GitClient(), new GitHubClient()).Register(door);
    var registration = door.RegisterCaller(new("ai", null, null, true, AiPermissionMode.Ask, CodeMcp.Specs.Select(s => s.Id).ToArray(), [McpTier.Read, McpTier.Act, McpTier.Alter], ["folders:" + root], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);
    var listed = await door.CallAsync(registration.Id, "files_list", Args(new { cwd = root }));
    Assert.Contains(listed.GetProperty("entries").EnumerateArray(), e => e.GetProperty("name").GetString() == "a.txt");
    var status = await door.CallAsync(registration.Id, "git.status", Args(new { cwd = root }));
    Assert.True(status.GetProperty("repo").GetBoolean());
    Assert.Empty(permission.Requests);
    await door.CallAsync(registration.Id, "git.stage", Args(new { cwd = root, paths = new[] { "a.txt" } }));
    Assert.Equal("git.stage", Assert.Single(permission.Requests).Tool);
    await door.CallAsync(registration.Id, "git.branch", Args(new { cwd = root, action = "list" }));
    Assert.Single(permission.Requests);
    Assert.Equal(McpTier.Act, McpCatalogue.EffectiveTier(catalogue.Single(s => s.Id == "git.branch"), Args(new { cwd = root, action = "create", name = "x" })));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(registration.Id, "files.list", Args(new { cwd = Path.GetTempPath() })));
    var plan = door.RegisterCaller(new("planner", null, null, true, AiPermissionMode.Plan, CodeMcp.Specs.Select(s => s.Id).ToArray(), [McpTier.Read, McpTier.Act, McpTier.Alter], ["folders:" + root], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(plan.Id, "git.commit", Args(new { cwd = root, message = "m" })));
  }
}
