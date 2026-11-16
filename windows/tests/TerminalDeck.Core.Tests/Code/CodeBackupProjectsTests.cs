using System.Text.Json;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Code;

/// Port of the Mac's BackendCodeBackupProjectsTests (L5 slice 1): the Code page's model on SCRATCH repositories only (a
/// temporary folder, a local bare remote standing in for GitHub through `url.<bare>.insteadOf`, no global or system Git
/// config), and a fake GitHub account. Every query must leave the repository byte-identical.
public sealed class CodeBackupProjectsTests : IDisposable
{
  private readonly CodeBackupScratch s = new();
  public void Dispose() => s.Dispose();
  private const long T1 = 1_794_000_000, T2 = 1_794_000_600, T3 = 1_794_001_200;
  private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_794_003_000);
  private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

  /// A repository whose origin reads as github.com/fixture-owner/<name> and really pushes to a bare folder here.
  private string PushedRepo(string name)
  {
    var bare = s.Folder(name + "-remote.git");
    s.Git(bare, "init", "-q", "--bare");
    var repo = s.Repo(name);
    var home = "https://github.com/fixture-owner/" + name + ".git";
    s.Git(repo, "remote", "add", "origin", home);
    s.Git(repo, "config", "url." + bare.Replace('\\', '/') + ".insteadOf", home);
    s.Commit(repo, "README.md", "first", T1);
    s.Git(repo, "push", "-q", "-u", "origin", "main");
    return repo;
  }

  private CodeBackupReader Reader(ICodeBackupGit? git = null, double projectSeconds = 30, double folderSeconds = 5, Func<string, bool>? isDirectory = null) =>
    new(git ?? s.Runner(), projectSeconds: projectSeconds, folderSeconds: folderSeconds, isDirectory: isDirectory, bounds: new([s.Home], Path.Combine(s.Home, "Terminal Deck"), _ => false));

  private async Task<CodeBackupProject> Read(IReadOnlyList<string> folders, CodeBackupReader? reader = null) =>
    (await (reader ?? Reader()).Read(new("fixture", "Fixture", folders))).Row;

  private async Task<CodeBackupProject> ReadUnchanged(string repo)
  {
    var before = CodeBackupScratch.Snapshot(repo);
    var row = await Read([repo]);
    Assert.Equal(before, CodeBackupScratch.Snapshot(repo));
    return row;
  }

  [Fact]
  public async Task CleanPushedRepositoryIsBackedUp()
  {
    var row = await ReadUnchanged(PushedRepo("clean"));
    Assert.Null(row.Problem);
    Assert.True(row.HasFolder && row.IsRepository);
    Assert.Equal("fixture-owner/clean", row.Home);
    Assert.Equal("main", row.Branch);
    Assert.Equal(T1 * 1000, row.LastBackedUpAt);
    Assert.Equal(0, row.ChangedCount); Assert.Equal(0, row.CommitCount); Assert.Empty(row.Held);
    Assert.Equal(CodeBackupState.BackedUp, row.State);
    Assert.Equal("Backed up", CodeBackupWords.Summary(row, Now, Utc));
    Assert.Equal("Last backed up Today, 21:20", CodeBackupWords.LastBackedUp(row, Now, Utc));
  }

  [Fact]
  public async Task AheadOfTheRemoteAndDirtyWithAStash()
  {
    var repo = PushedRepo("ahead");
    s.Commit(repo, "a.txt", "second", T2); s.Commit(repo, "b.txt", "third", T3);
    s.Write(repo, "a.txt", "stashed\n"); s.Git(repo, "stash", "-q");
    s.Write(repo, "README.md", "edited\n"); s.Write(repo, "notes/new.txt", "new\n");
    s.Git(repo, "add", "README.md");
    var row = await ReadUnchanged(repo);
    Assert.Equal(T1 * 1000, row.LastBackedUpAt);
    Assert.Equal(2, row.CommitCount);
    Assert.Equal(["third", "second"], row.Commits.Select(c => c.Subject));
    Assert.Equal(2, row.ChangedCount);
    Assert.Equal(["README.md", "notes/new.txt"], row.ChangedFiles.Order(StringComparer.Ordinal));
    Assert.Equal(T3 * 1000, row.LastCommitAt);
    Assert.Equal(CodeBackupState.CommitsNotOnGitHub, row.State);
    Assert.Equal(1, row.SetAsideCount);
    Assert.Equal("2 commits not on GitHub · 2 files changed since 21:40 · 1 set-aside change not on GitHub", CodeBackupWords.Summary(row, Now, Utc));
    Assert.Single(s.Git(repo, "stash", "list").Split('\n', StringSplitOptions.RemoveEmptyEntries));
  }

  [Fact]
  public async Task ABranchPushedLaterCountsAsBackedUp()
  {
    var repo = PushedRepo("branches");
    s.Git(repo, "checkout", "-q", "-b", "feature"); s.Commit(repo, "f.txt", "feature work", T2);
    s.Git(repo, "push", "-q", "origin", "feature"); s.Git(repo, "checkout", "-q", "main");
    var row = await ReadUnchanged(repo);
    Assert.Equal(T2 * 1000, row.LastBackedUpAt);
    Assert.Equal(CodeBackupState.BackedUp, row.State);
  }

  [Fact]
  public async Task NoRemoteMeansNoGitHubHome()
  {
    var repo = s.Repo("local"); s.Commit(repo, "a.txt", "only here", T1);
    var row = await ReadUnchanged(repo);
    Assert.Null(row.Home); Assert.Null(row.LastBackedUpAt);
    Assert.Equal(CodeBackupState.NoHome, row.State);
    Assert.Equal("Not on GitHub yet", CodeBackupWords.Summary(row, Now, Utc));
    Assert.Equal("Never backed up", CodeBackupWords.LastBackedUp(row, Now, Utc));
  }

  [Fact]
  public async Task ARemoteNeverPushedHasEveryCommitWaiting()
  {
    var repo = s.Repo("never");
    s.Git(repo, "remote", "add", "origin", "git@github.com:fixture-owner/never.git");
    s.Commit(repo, "a.txt", "one", T1); s.Commit(repo, "b.txt", "two", T2);
    var row = await ReadUnchanged(repo);
    Assert.Equal("fixture-owner/never", row.Home);
    Assert.Equal(2, row.CommitCount); Assert.Null(row.LastBackedUpAt);
    Assert.Equal("2 commits not on GitHub", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task DetachedHead()
  {
    var repo = PushedRepo("detached");
    s.Commit(repo, "a.txt", "second", T2);
    s.Git(repo, "checkout", "-q", "--detach", "HEAD~1");
    var row = await ReadUnchanged(repo);
    Assert.Null(row.Branch);
    Assert.Equal(1, row.CommitCount);
    var wire = CodeBackupTools.Wire(new([row], false, 0), null, Now, Utc);
    Assert.Equal(CodeBackupWords.NotOnBranch, wire.GetProperty("projects")[0].GetProperty("branch").GetString());
  }

  [Fact]
  public async Task HugeIgnoredFolderLargeFileAndSecretFile()
  {
    var repo = PushedRepo("heavy");
    s.Write(repo, ".gitignore", "build/\n");
    s.Git(repo, "add", "-A"); s.GitAt(repo, T2, "commit", "-q", "-m", "ignore build"); s.Git(repo, "push", "-q");
    for (var folder = 0; folder < 20; folder++) for (var file = 0; file < 150; file++) s.Write(repo, $"build/f{folder}/o{file}.o", "x");
    Directory.CreateDirectory(Path.Combine(repo, "media"));
    using (var big = File.Create(Path.Combine(repo, "media", "big.mov"))) big.SetLength(60L * 1024 * 1024);
    s.Write(repo, ".env", "KEY=fixture\n"); s.Write(repo, ".env.example", "KEY=\n"); s.Write(repo, "config/server.pem", "fixture\n");
    var started = DateTimeOffset.UtcNow;
    var row = await ReadUnchanged(repo);
    Assert.True((DateTimeOffset.UtcNow - started).TotalSeconds < 20, "the ignored folder is never walked");
    Assert.Equal(4, row.ChangedCount);
    Assert.DoesNotContain(row.ChangedFiles, f => f.StartsWith("build/", StringComparison.Ordinal));
    Assert.Equal(new CodeBackupHeld[] { new(".env", CodeBackupHeldReason.LooksSecret), new(".env.example", CodeBackupHeldReason.LooksSecret), new("media/big.mov", CodeBackupHeldReason.TooLarge) }, row.Held);
    Assert.Equal("4 files changed since 21:30 · 1 file too large · 2 secret files not sent to GitHub", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task PlainFolderAndNoFolder()
  {
    var plain = s.Folder("plain");
    var row = await Read([plain]);
    Assert.True(row.HasFolder); Assert.False(row.IsRepository); Assert.Null(row.Problem);
    Assert.Equal("plain", row.FolderName);
    Assert.Equal(CodeBackupState.NoHome, row.State);
    var none = await Read([]);
    Assert.Equal(CodeBackupState.NoFolder, none.State);
    Assert.Equal("No code folder on this PC", CodeBackupWords.Summary(none, Now));
    Assert.Equal("", CodeBackupWords.LastBackedUp(none, Now));
    Assert.Equal(CodeBackupState.NoFolder, (await Read([Path.Combine(s.Root, "gone")])).State);
  }

  [Fact]
  public async Task GitMissingCouldNotCheck()
  {
    var repo = PushedRepo("nogit");
    var row = await Read([repo], Reader(s.Runner(Path.Combine(s.Root, "no-bin", "git.exe"))));
    Assert.Equal(CodeBackupState.CouldNotCheck, row.State);
    Assert.Equal("Could not check (Git is not installed on this PC)", CodeBackupWords.Summary(row, Now));
  }

  // ---- the model: GitHub, cache, order ----

  private sealed class FakeAccount(bool signedIn, Dictionary<string, bool> listed, double delaySeconds = 0) : ICodeBackupAccount
  {
    public List<string> Asked { get; } = [];
    public Task<string?> Login() => Task.FromResult<string?>(signedIn ? "fixture-owner" : null);
    public Task<IReadOnlyList<CodeBackupRepo>> Repositories() => Task.FromResult<IReadOnlyList<CodeBackupRepo>>(listed.Select(l => new CodeBackupRepo(l.Key, l.Value, true)).ToList());
    public async Task<CodeBackupRepo?> Repository(string home)
    {
      lock (Asked) Asked.Add(home);
      if (delaySeconds > 0) await Task.Delay(TimeSpan.FromSeconds(delaySeconds));
      if (delaySeconds > 0) return new(home, false, true);
      return home == "fixture-owner/clean" ? new(home, true, true) : null;
    }
    public Task<CodeBackupCreated> Create(string name, string description) => Task.FromResult<CodeBackupCreated>(new CodeBackupCreated.Refused("fixture"));
    public Task<CodeBackupTransport?> Transport(string home) => Task.FromResult<CodeBackupTransport?>(null);
    public Task<bool> Quiet(string home) => Task.FromResult(false);
  }

  [Fact]
  public async Task PrivatePublicFromGitHubAndTheCache()
  {
    var clean = PushedRepo("clean"); var site = PushedRepo("site");
    var counting = new CountingGit(s.Runner());
    var account = new FakeAccount(true, new() { ["fixture-owner/site"] = false });
    IReadOnlyList<CodeBackupProjectRef> list = [new("a", "Clean", [clean]), new("b", "Site", [site]), new("c", "Notes", [])];
    var model = new CodeBackupProjects(() => Task.FromResult(list), Reader(counting), new CodeBackupGitHub(account));
    var facts = await model.Report();
    Assert.Null(facts.SignedInToGitHub);
    Assert.Equal(CodeBackupVisibility.NotChecked, facts.Projects[0].Visibility);
    var report = await model.WithGitHub(facts);
    Assert.True(report.SignedInToGitHub);
    Assert.Equal(["Clean", "Site", "Notes"], report.Projects.Select(p => p.Name));
    Assert.Equal(CodeBackupVisibility.Private, report.Projects.First(p => p.Name == "Clean").Visibility);
    Assert.Equal(CodeBackupVisibility.Public, report.Projects.First(p => p.Name == "Site").Visibility);
    Assert.Equal(["fixture-owner/clean"], account.Asked);
    var wire = CodeBackupTools.Wire(report, null, Now).GetRawText();
    Assert.DoesNotContain(s.Root.Replace("\\", "\\\\"), wire);
    Assert.DoesNotContain("\"a\"", wire);
    // Kept until something changes: a second look runs no Git at all.
    var calls = counting.Calls;
    await model.Report();
    Assert.Equal(calls, counting.Calls);
    // GitHub's answers are kept: asked again within five minutes, nothing is fetched.
    var kept = await model.WithGitHub(await model.Report());
    Assert.Single(account.Asked);
    Assert.Equal(CodeBackupVisibility.Private, kept.Projects.First(p => p.Name == "Clean").Visibility);
    // A commit changes HEAD: that project alone is read again.
    await Task.Delay(50);
    s.Commit(site, "x.txt", "later", T3);
    var after = await model.Report();
    Assert.True(counting.Calls > calls);
    Assert.Equal("Site", after.Projects[0].Name);
    Assert.Equal(1, after.Projects[0].CommitCount);
    var beforeRefresh = counting.Calls;
    await model.Report(refresh: true);
    Assert.True(counting.Calls > beforeRefresh);
  }

  [Fact]
  public async Task SignedOutShowsNotChecked()
  {
    var clean = PushedRepo("clean");
    var account = new FakeAccount(false, []);
    var model = new CodeBackupProjects(() => Task.FromResult<IReadOnlyList<CodeBackupProjectRef>>([new("a", "Clean", [clean])]), Reader(), new CodeBackupGitHub(account));
    var report = await model.WithGitHub(await model.Report());
    Assert.False(report.SignedInToGitHub);
    Assert.Equal(CodeBackupVisibility.NotChecked, report.Projects[0].Visibility);
    Assert.Equal(CodeBackupState.BackedUp, report.Projects[0].State);
    Assert.Empty(account.Asked);
    Assert.Equal("GitHub is not connected", CodeBackupTools.Wire(report, null, Now).GetProperty("note").GetString());
  }

  // ---- review fixes: never "Backed up" while work exists only here ----

  [Fact]
  public async Task AChangedSubmoduleCountsAsAChangedFile()
  {
    var sub = PushedRepo("library"); var repo = PushedRepo("withsub");
    s.Git(repo, "submodule", "add", "-q", sub, "library");
    s.GitAt(repo, T2, "commit", "-q", "-m", "add library"); s.Git(repo, "push", "-q");
    s.Write(repo, "library/README.md", "changed inside the submodule\n");
    var row = await ReadUnchanged(repo);
    Assert.Equal(["library"], row.ChangedFiles);
    Assert.Equal(CodeBackupState.FilesChanged, row.State);
  }

  [Fact]
  public async Task AnUnpushedCommitInsideASubmoduleIsNotBackedUp()
  {
    var sub = PushedRepo("widgets"); var repo = PushedRepo("outer");
    s.Git(repo, "submodule", "add", "-q", sub, "widgets");
    s.GitAt(repo, T2, "commit", "-q", "-m", "add widgets"); s.Git(repo, "push", "-q");
    var inside = Path.Combine(repo, "widgets");
    s.Commit(inside, "w.txt", "made inside the submodule", T3);
    s.Git(repo, "add", "widgets"); s.GitAt(repo, T3, "commit", "-q", "-m", "move widgets"); s.Git(repo, "push", "-q");
    var row = await ReadUnchanged(repo);
    Assert.Equal(["outer", "widgets"], row.Parts.Select(p => p.FolderName ?? ""));
    Assert.Equal(CodeBackupState.BackedUp, row.Parts[0].State);
    Assert.Equal(1, row.Parts[^1].CommitCount);
    Assert.NotEqual(CodeBackupState.BackedUp, row.State);
    Assert.Equal("widgets: 1 commit not pushed", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task APlainFolderBesideAPushedRepositoryIsNotBackedUp()
  {
    var repo = PushedRepo("pushed");
    var plain = s.Folder("designs"); s.Write(plain, "logo.sketch", "only here\n");
    var row = await Read([repo, plain]);
    Assert.Equal([CodeBackupState.BackedUp, CodeBackupState.NoHome], row.Parts.Select(p => p.State));
    Assert.Equal(CodeBackupState.NoHome, row.State);
    Assert.Equal("designs: Not on GitHub yet", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task ANestedRepositoryTheGitignoreHidesIsItsOwnRow()
  {
    var repo = PushedRepo("host");
    s.Write(repo, ".gitignore", "vendor/\n");
    s.Git(repo, "add", "-A"); s.GitAt(repo, T2, "commit", "-q", "-m", "ignore vendor"); s.Git(repo, "push", "-q");
    var nested = Path.Combine(repo, "vendor", "tool"); Directory.CreateDirectory(nested);
    s.Git(nested, "init", "-q"); s.Commit(nested, "t.txt", "only here", T3);
    var row = await ReadUnchanged(repo);
    Assert.Equal(["host", "tool"], row.Parts.Select(p => p.FolderName ?? ""));
    Assert.Equal(CodeBackupState.NoHome, row.State);
    Assert.Equal([nested], CodeBackupReader.Nested(repo));
  }

  [Fact]
  public async Task OnlyAStashIsNotBackedUp()
  {
    var repo = PushedRepo("stashonly");
    s.Write(repo, "README.md", "set aside\n"); s.Git(repo, "stash", "-q");
    var row = await ReadUnchanged(repo);
    Assert.Equal(0, row.ChangedCount); Assert.Equal(0, row.CommitCount); Assert.Equal(1, row.SetAsideCount);
    Assert.Equal(CodeBackupState.SetAside, row.State);
    Assert.Equal("1 set-aside change not on GitHub", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task ACommitOnlyOnAnotherRemoteIsNotOnGitHub()
  {
    var repo = PushedRepo("tworemotes");
    var other = s.Folder("elsewhere.git"); s.Git(other, "init", "-q", "--bare");
    s.Git(repo, "remote", "add", "backup", other);
    s.Commit(repo, "a.txt", "only on backup", T2);
    s.Git(repo, "push", "-q", "backup", "main");
    var row = await ReadUnchanged(repo);
    Assert.Equal("fixture-owner/tworemotes", row.Home);
    Assert.Equal(1, row.CommitCount);
    Assert.Equal(T1 * 1000, row.LastBackedUpAt);
    Assert.Equal("1 commit not on GitHub", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task EveryCodeFolderIsReadAndTheWorstShows()
  {
    var clean = PushedRepo("api"); var dirty = PushedRepo("app");
    s.Write(dirty, "new.txt", "new\n");
    var plain = s.Folder("docs");
    var before = (CodeBackupScratch.Snapshot(clean), CodeBackupScratch.Snapshot(dirty));
    var row = await Read([clean, plain, dirty, dirty + Path.DirectorySeparatorChar]);
    Assert.Equal(before.Item1, CodeBackupScratch.Snapshot(clean)); Assert.Equal(before.Item2, CodeBackupScratch.Snapshot(dirty));
    Assert.Equal(["api", "docs", "app"], row.Parts.Select(p => p.FolderName ?? ""));
    Assert.Equal(CodeBackupState.NoHome, row.Parts[1].State);
    Assert.Equal(CodeBackupState.FilesChanged, row.State);
    Assert.Equal("app: 1 file changed since 21:20", CodeBackupWords.Summary(row, Now, Utc));
    Assert.Equal(CodeBackupState.BackedUp, row.Parts[0].State);
    var broken = row.Parts[0].Clone(); broken.Problem = "the folder took too long to read";
    Assert.NotEqual(CodeBackupState.BackedUp, CodeBackupProject.Combine("x", "X", [row.Parts[0], broken]).State);
  }

  [Fact]
  public async Task SecretFilesInCommitsAndNotSent()
  {
    var repo = PushedRepo("secrets");
    s.Write(repo, ".env", "KEY=committed\n");
    s.Git(repo, "add", "-A"); s.GitAt(repo, T2, "commit", "-q", "-m", "oops"); s.Git(repo, "push", "-q");
    var row = await ReadUnchanged(repo);
    Assert.Equal([".env"], row.SecretsInCommits); Assert.Empty(row.Held);
    Assert.Equal(CodeBackupState.SecretsInCommits, row.State);
    Assert.Equal("1 secret file is in your commits", CodeBackupWords.Summary(row, Now, Utc));
    s.Write(repo, ".gitignore", "local.pem\n"); s.Write(repo, "id_rsa", "k\n"); s.Write(repo, "local.pem", "ignored\n");
    s.Git(repo, "add", ".gitignore"); s.GitAt(repo, T3, "commit", "-q", "-m", "ignore"); s.Git(repo, "push", "-q");
    row = await ReadUnchanged(repo);
    Assert.Equal(new[] { new CodeBackupHeld("id_rsa", CodeBackupHeldReason.LooksSecret) }, row.Held);
    Assert.Equal("1 file changed since 21:40 · 1 secret file is in your commits · 1 secret file not sent to GitHub", CodeBackupWords.Summary(row, Now, Utc));
  }

  [Fact]
  public async Task ARepositoryWhoseSettingsRunProgramsIsNotRead()
  {
    var marker = Path.Combine(s.Root, "ran");
    var repo = PushedRepo("filtered");
    s.Write(repo, ".gitattributes", "* filter=evil\n");
    s.Git(repo, "config", "filter.evil.clean", "touch \"" + marker.Replace('\\', '/') + "\"");
    var row = await ReadUnchanged(repo);
    Assert.Equal("Could not check (this folder's Git settings run programs)", CodeBackupWords.Summary(row, Now));
    Assert.False(File.Exists(marker));
    var included = PushedRepo("included");
    s.Write(s.Root, "extra.gitconfig", "[filter \"inc\"]\n\tsmudge = touch \"" + marker.Replace('\\', '/') + "\"\n");
    s.Git(included, "config", "include.path", Path.Combine(s.Root, "extra.gitconfig").Replace('\\', '/'));
    var second = await ReadUnchanged(included);
    Assert.Equal("this folder's Git settings run programs", second.Problem);
    Assert.False(File.Exists(marker));
  }

  [Fact]
  public async Task AFilterInThePerWorktreeSettingsIsRefused()
  {
    var marker = Path.Combine(s.Root, "ran-worktree");
    var repo = PushedRepo("worktreecfg");
    s.Write(repo, ".gitattributes", "* filter=wt\n");
    s.Git(repo, "config", "core.repositoryformatversion", "1");
    s.Git(repo, "config", "extensions.worktreeConfig", "true");
    s.Git(repo, "config", "--worktree", "filter.wt.clean", "touch \"" + marker.Replace('\\', '/') + "\"");
    var row = await ReadUnchanged(repo);
    Assert.Equal("this folder's Git settings run programs", row.Problem);
    Assert.False(File.Exists(marker));
    Assert.True(CodeBackupReader.RepositoryRunsPrograms("worktree\tfilter.wt.clean touch x\n"));
    Assert.True(CodeBackupReader.RepositoryRunsPrograms("local\tfilter.a.smudge x\n"));
    Assert.False(CodeBackupReader.RepositoryRunsPrograms("global\tfilter.lfs.process git-lfs filter-process\nsystem\tfilter.x.clean y\n"));
  }

  [Fact]
  public async Task ASubmodulesOwnFilterStopsTheOuterRead()
  {
    var marker = Path.Combine(s.Root, "ran-submodule");
    var sub = PushedRepo("parts"); var repo = PushedRepo("assembly");
    s.Git(repo, "submodule", "add", "-q", sub, "parts");
    s.GitAt(repo, T2, "commit", "-q", "-m", "add parts");
    var inside = Path.Combine(repo, "parts");
    s.Write(inside, ".gitattributes", "* filter=sub\n");
    s.Git(inside, "config", "filter.sub.clean", "touch \"" + marker.Replace('\\', '/') + "\"");
    var row = await ReadUnchanged(repo);
    Assert.Equal(CodeBackupState.CouldNotCheck, row.State);
    Assert.False(File.Exists(marker));
  }

  [Fact]
  public async Task APlainFolderInsideAHomeRepositoryIsNotTheHome()
  {
    s.Git(s.Home, "init", "-q");
    var plain = Path.Combine(s.Home, "plain"); Directory.CreateDirectory(plain);
    var row = await Read([plain]);
    Assert.False(row.IsRepository);
    Assert.Equal(CodeBackupState.NoHome, row.State);
  }

  [Fact]
  public async Task OneTimeLimitPerProjectAndForTheFolderCheck()
  {
    var repo = PushedRepo("slow");
    var started = DateTimeOffset.UtcNow;
    var slow = await Read([repo], Reader(new HangingGit(), projectSeconds: 0.5));
    Assert.True((DateTimeOffset.UtcNow - started).TotalSeconds < 5);
    Assert.Equal("Could not check (the folder took too long to read)", CodeBackupWords.Summary(slow, Now));
    started = DateTimeOffset.UtcNow;
    var silent = await Read([repo], Reader(folderSeconds: 0.3, isDirectory: _ => { Thread.Sleep(3000); return true; }));
    Assert.True((DateTimeOffset.UtcNow - started).TotalSeconds < 2);
    Assert.Equal("Could not check (the folder did not answer)", CodeBackupWords.Summary(silent, Now));
    var remembered = await Read([repo]);
    Assert.Equal("the folder did not answer", remembered.Problem);
    Assert.Equal(["lib/widgets"], CodeBackupReader.Gitlinks("100644 abc 0\tREADME.md\0" + "160000 def 0\tlib/widgets\0"));
  }

  [Fact]
  public async Task GitHubLookupsRunTogetherWithinOneLimit()
  {
    var github = new CodeBackupGitHub(new FakeAccount(true, [], delaySeconds: 0.6));
    var started = DateTimeOffset.UtcNow;
    var answer = await github.Visibility(new HashSet<string> { "o/a", "o/b", "o/c", "o/d", "o/e" });
    Assert.True((DateTimeOffset.UtcNow - started).TotalSeconds < 2.5);
    Assert.Equal(5, answer.Found.Count);
    var clean = PushedRepo("offline");
    var stuck = new CodeBackupGitHub(new FakeAccount(true, [], delaySeconds: 30));
    var model = new CodeBackupProjects(() => Task.FromResult<IReadOnlyList<CodeBackupProjectRef>>([new("a", "Offline", [clean])]), Reader(), stuck, githubSeconds: 0.5);
    started = DateTimeOffset.UtcNow;
    var report = await model.WithGitHub(await model.Report());
    Assert.True((DateTimeOffset.UtcNow - started).TotalSeconds < 5);
    Assert.Equal(CodeBackupVisibility.NotChecked, report.Projects[0].Visibility);
    Assert.Equal(CodeBackupState.BackedUp, report.Projects[0].State);
  }

  // ---- plain rules ----

  [Fact]
  public void GitHubHomesAndHosts()
  {
    foreach (var url in new[] { "https://github.com/o/n.git", "https://github.com/o/n", "git@github.com:o/n.git", "ssh://git@github.com/o/n.git", "https://user@github.com/o/n.git/", "ssh://git@github.com:22/o/n.git" })
      Assert.Equal("o/n", CodeBackupReader.GitHubHome(url, "github.com"));
    Assert.Null(CodeBackupReader.GitHubHome("https://gitlab.com/o/n.git", "github.com"));
    Assert.Null(CodeBackupReader.GitHubHome("/tmp/bare.git", "github.com"));
    Assert.Null(CodeBackupReader.GitHubHome(@"C:\repos\bare.git", "github.com"));
    Assert.Equal("gitlab.com", CodeBackupReader.Host("https://gitlab.com/o/n.git"));
    Assert.Equal("a folder on this PC", CodeBackupReader.Host("/srv/bare.git"));
    Assert.Equal("a folder on this PC", CodeBackupReader.Host(@"D:\srv\bare.git"));
    Assert.Equal(["a.txt", "b c.txt"], CodeBackupReader.StatusNames(" M a.txt\0?? b c.txt\0"));
  }

  [Fact]
  public void SecretPatterns()
  {
    foreach (var yes in new[] { ".env", "a/.env.local", "id_rsa", "x/server.pem", "k.key", "credentials-prod.json", ".netrc" }) Assert.True(CodeBackupReader.IsSecret(yes), yes);
    foreach (var no in new[] { "environment.ts", "README.md", "keys.txt" }) Assert.False(CodeBackupReader.IsSecret(no), no);
  }

  [Fact]
  public void OrderAndWords()
  {
    var backed = new CodeBackupProject("1", "Backed") { HasFolder = true, IsRepository = true, Home = "o/b", LastBackedUpAt = 1_794_000_000_000 };
    var changed = new CodeBackupProject("2", "Changed") { HasFolder = true, IsRepository = true, Home = "o/c", ChangedCount = 1, LastCommitAt = 1_700_000_000_000 };
    var none = new CodeBackupProject("3", "Absent");
    var broken = new CodeBackupProject("4", "Broken") { HasFolder = true, Problem = "the folder took too long to read" };
    var report = new CodeBackupReport([none, backed, broken, changed], true, 0);
    Assert.Equal(["Changed", "Broken", "Backed", "Absent"], report.Projects.Select(p => p.Name));
    Assert.Equal("1 file changed since 14 Nov 2023", CodeBackupWords.Summary(changed, Now, Utc));
    Assert.Equal("Could not check (the folder took too long to read)", CodeBackupWords.Summary(broken, Now));
    Assert.Equal("Yesterday, 17:33", CodeBackupWords.When(1_793_900_000_000, Now, Utc));
    Assert.Equal("21 Sep, 14:13", CodeBackupWords.When(1_790_000_000_000, Now, Utc));
  }
}
