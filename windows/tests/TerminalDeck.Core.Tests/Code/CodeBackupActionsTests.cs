using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Code;

/// GitHub's API as a fake: repositories are bare folders under the scratch root. Never reaches the network.
public sealed class FakeGitHub(CodeBackupScratch s, string root) : ICodeBackupAccount
{
  private readonly object gate = new();
  private readonly Dictionary<string, (CodeBackupRepo Repo, string Folder)> repos = new(StringComparer.OrdinalIgnoreCase);
  public List<string> Created { get; } = [];
  public string Account { get; set; } = "fixture-owner";

  public string Add(string home, bool isPrivate, string? description = null)
  {
    var folder = Path.Combine(root, "github", home.Replace('/', Path.DirectorySeparatorChar) + ".git");
    Directory.CreateDirectory(folder);
    s.Git(folder, "init", "-q", "--bare");
    lock (gate) repos[home] = (new(home, isPrivate, true, description), folder);
    return folder;
  }
  public void Alias(string home, string existing, bool canPush) { lock (gate) if (repos.TryGetValue(existing, out var found)) repos[home] = (new(home, true, canPush), found.Folder); }
  public string Bare(string home) { lock (gate) return repos.TryGetValue(home, out var r) ? r.Folder : Path.Combine(root, "missing"); }
  public CodeBackupRepo? Named(string home) { lock (gate) return repos.TryGetValue(home, out var r) ? r.Repo : null; }

  public Task<string?> Login() => Task.FromResult<string?>(Account);
  public Task<IReadOnlyList<CodeBackupRepo>> Repositories() { lock (gate) return Task.FromResult<IReadOnlyList<CodeBackupRepo>>(repos.Values.Select(r => r.Repo).OrderBy(r => r.NameWithOwner, StringComparer.Ordinal).ToList()); }
  public Task<CodeBackupRepo?> Repository(string home) => Task.FromResult(Named(home));
  public Task<CodeBackupCreated> Create(string name, string description)
  {
    var home = Account + "/" + name;
    if (Named(home) is not null) return Task.FromResult<CodeBackupCreated>(new CodeBackupCreated.Taken());
    Add(home, true, description);
    lock (gate) Created.Add(home);
    return Task.FromResult<CodeBackupCreated>(new CodeBackupCreated.Made(new(home, true, true, description)));
  }
  public Task<bool> Quiet(string home) => Task.FromResult(true);
  public Task<CodeBackupTransport?> Transport(string home) =>
    Task.FromResult<CodeBackupTransport?>(Named(home) is null ? null : new CodeBackupTransport(Bare(home), CodeBackupGitRunner.Settings([("protocol.file.allow", "always")])));
}

/// The real Git, with something happening in the folder right before the app's `git init` runs.
public sealed class BeforeInit(ICodeBackupGit real, Action<string> before) : ICodeBackupGit
{
  public Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default)
  {
    if (arguments.FirstOrDefault() == "init") before(cwd);
    return real.RunAsync(cwd, arguments, environment, timeoutMilliseconds, maximumBytes, ct);
  }
}

/// The real Git, except that the first command containing `word` fails as if the PC had been interrupted.
public sealed class FailingOnce(ICodeBackupGit real, string word) : ICodeBackupGit
{
  private int failed;
  public Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default)
  {
    if (arguments.Contains(word) && Interlocked.Exchange(ref failed, 1) == 0) return Task.FromResult(new CodeProcessResult(143, "", "interrupted", TimedOut: true));
    return real.RunAsync(cwd, arguments, environment, timeoutMilliseconds, maximumBytes, ct);
  }
}

/// Port of the Mac's BackendCodeBackupActionsTests (L5 slice 2) on SCRATCH repositories only. Local bare repositories stand
/// in for GitHub (the fake account hands Git their folder as the address), the GitHub API is a fake, and no request ever
/// leaves the PC. Every repository the tests make has its origin set to a github.com address that nothing ever contacts.
public sealed class CodeBackupActionsTests : IDisposable
{
  private readonly CodeBackupScratch s = new();
  public void Dispose() => s.Dispose();
  private const long T1 = 1_794_000_000, T2 = 1_794_000_600, T3 = 1_794_001_200;
  private const string Area = "refs/terminal-deck-backup/Test-PC/";

  private sealed class Clock { public DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_794_003_000); public void Advance(double seconds) => At = At.AddSeconds(seconds); }
  private sealed record Rig(CodeBackupActions Actions, CodeBackupProjects Projects, CodeBackupLedger Ledger);
  private sealed class NoGitHub : ICodeBackupGitHubReading
  {
    public Task<CodeBackupGitHubAnswer> Visibility(IReadOnlySet<string> homes) => Task.FromResult(new CodeBackupGitHubAnswer(true, new Dictionary<string, CodeBackupVisibility>()));
  }

  private CodeBackupProjectCode.Bounds Bounds(params string[] made)
  {
    var resolved = made.Select(CodeBackupProjectCode.Resolved).ToHashSet(StringComparer.OrdinalIgnoreCase);
    return new([s.Home], Path.Combine(s.Home, "Terminal Deck"), folder => resolved.Contains(CodeBackupProjectCode.Resolved(folder)));
  }

  private Rig MakeRig(IReadOnlyList<CodeBackupProjectRef> list, FakeGitHub github, string[]? made = null, Clock? clock = null, bool network = true, ICodeBackupGit? git = null)
  {
    var ledger = new CodeBackupLedger(null);
    var fence = Bounds(made ?? []);
    var reader = new CodeBackupReader(s.Runner(), bounds: fence, coverage: ledger.Coverage);
    var projects = new CodeBackupProjects(() => Task.FromResult(list), reader, new NoGitHub());
    var time = clock ?? new Clock();
    var actions = new CodeBackupActions(projects, ledger, github, git ?? s.Runner(), "github.com", "Test-PC", "Test PC", () => fence, () => network, () => time.At, Path.Combine(s.Root, "app-data"));
    return new(actions, projects, ledger);
  }

  /// A repository whose origin reads as github.com/fixture-owner/<name>; its "GitHub" is a bare folder made by the fake.
  private string HomedRepo(string name, FakeGitHub github, bool isPrivate = true)
  {
    var bare = github.Add("fixture-owner/" + name, isPrivate);
    var repo = s.Repo(name);
    s.Git(repo, "remote", "add", "origin", "https://github.com/fixture-owner/" + name + ".git");
    s.Commit(repo, "README.md", "first", T1);
    s.Git(repo, "push", "-q", bare, "main:refs/heads/main");
    s.Git(repo, "update-ref", "refs/remotes/origin/main", "HEAD");
    return repo;
  }
  private FakeGitHub NewGitHub(string? root = null) => new(s, root ?? s.Root);
  private static CodeBackupProjectRef P(string id, string name, params string[] folders) => new(id, name, folders);

  // ---- Back up now adds only ----

  [Fact]
  public async Task BackUpAddsOnlyAndNeverChangesHisSide()
  {
    var github = NewGitHub();
    var repo = HomedRepo("site", github);
    var bare = github.Bare("fixture-owner/site");
    s.Git(repo, "tag", "v1"); s.Git(repo, "push", "-q", bare, "refs/tags/v1:refs/tags/v1");
    s.Git(repo, "checkout", "-q", "-b", "diverged"); s.Commit(repo, "d.txt", "his diverged", T2);
    s.Git(repo, "checkout", "-q", "-b", "elsewhere", "main"); s.Commit(repo, "e.txt", "theirs", T2);
    s.Git(repo, "push", "-q", bare, "elsewhere:refs/heads/diverged", "elsewhere:refs/heads/only-there");
    s.Git(repo, "checkout", "-q", "main"); s.Git(repo, "branch", "-q", "-D", "elsewhere");
    s.Commit(repo, "a.txt", "second", T2);
    s.Git(repo, "checkout", "-q", "-b", "feature"); s.Commit(repo, "f.txt", "feature work", T3); s.Git(repo, "checkout", "-q", "main");
    s.Write(repo, "a.txt", "stashed\n"); s.Git(repo, "stash", "-q");
    s.Write(repo, "README.md", "staged\n"); s.Git(repo, "add", "README.md");
    s.Write(repo, "README.md", "edited after staging\n");
    s.Write(repo, "notes/new.txt", "new\n"); s.Write(repo, ".env", "TOKEN=fixture\n");
    var remoteBefore = s.Refs(bare); var sideBefore = s.HisSide(repo);
    var objectsBefore = CodeBackupScratch.Snapshot(Path.Combine(bare, "objects")).Keys.ToHashSet();

    var rig = MakeRig([P("site", "Site", repo)], github);
    var outcome = await rig.Actions.BackUp("site");
    Assert.True(outcome.Ok, outcome.Line);
    Assert.StartsWith("Backed up to github.com/fixture-owner/site", outcome.Line);
    Assert.Contains("1 file left out (secret files)", outcome.Line);

    var remoteAfter = s.Refs(bare);
    Dictionary<string, string> Real(Dictionary<string, string> all) => all.Where(r => r.Key.StartsWith("refs/heads/") || r.Key.StartsWith("refs/tags/")).ToDictionary();
    Assert.Equal(Real(remoteBefore), Real(remoteAfter));
    foreach (var name in remoteAfter.Keys.Except(remoteBefore.Keys)) Assert.StartsWith(Area, name);
    Assert.Subset(CodeBackupScratch.Snapshot(Path.Combine(bare, "objects")).Keys.ToHashSet(), objectsBefore);
    foreach (var branch in new[] { "main", "feature", "diverged" })
      Assert.Equal(s.GitTrim(repo, "rev-parse", branch), s.GitTrim(bare, "rev-parse", remoteAfter[Area + "heads/" + branch] + "^1"));
    var work = remoteAfter[Area + "work/main"];
    Assert.True(remoteAfter.ContainsKey(Area + "set-aside"));
    Assert.Equal("edited after staging\n", s.Git(bare, "show", work + ":README.md"));
    Assert.Equal("new\n", s.Git(bare, "show", work + ":notes/new.txt"));
    Assert.Throws<InvalidOperationException>(() => s.Git(bare, "show", work + ":.env"));
    Assert.Equal(sideBefore, s.HisSide(repo));
    Assert.Equal("README.md", s.GitTrim(repo, "diff", "--cached", "--name-only"));
  }

  [Fact]
  public void TheRuleItselfCannotForceOrDelete()
  {
    var sha = new string('a', 40);
    Assert.True(CodeBackupPlan.AddsOnly(sha + ":refs/heads/main"));
    Assert.True(CodeBackupPlan.AddsOnly(sha + ":refs/tags/v1"));
    foreach (var refused in new[] { "+" + sha + ":refs/heads/main", ":refs/heads/main", sha + ":refs/remotes/origin/main", "main:refs/heads/main", sha + ":refs/heads/*",
      "refs/heads/*:refs/heads/*", sha + ":refs/heads/a..b", sha + ":refs/heads/x.lock", "^" + sha + ":refs/heads/main", sha + ":refs/heads/main:refs/heads/x", sha + ":HEAD" })
      Assert.False(CodeBackupPlan.AddsOnly(refused), refused);
    Assert.True(CodeBackupPlan.AddsOnly(sha + ":refs/terminal-deck-backup/PC/heads/main"));
    Assert.False(CodeBackupPlan.AddsOnly("+" + sha + ":refs/terminal-deck-backup/PC/heads/main"));
    Assert.True(CodeBackupPlan.PrivateOnly([new(sha, "refs/terminal-deck-backup/PC/heads/main"), new(sha, "refs/terminal-deck-backup/PC/tags/v1")]));
    Assert.False(CodeBackupPlan.PrivateOnly([new(sha, "refs/terminal-deck-backup/PC/heads/main"), new(sha, "refs/heads/main")]));
    Assert.False(CodeBackupPlan.PrivateOnly([new(sha, "refs/tags/v1")]));
    var plan = CodeBackupPlan.Make(new Dictionary<string, string> { ["main"] = sha, ["new"] = sha, ["behind"] = sha }, new Dictionary<string, string> { ["v1"] = sha, ["v2"] = sha },
      new Dictionary<string, string> { ["refs/heads/main"] = "b" + sha[1..], ["refs/heads/behind"] = "c" + sha[1..], ["refs/tags/v1"] = "d" + sha[1..] }, (theirs, _) => theirs.StartsWith('b'));
    Assert.Equal(["refs/heads/main", "refs/heads/new", "refs/tags/v2"], plan.Send.Select(x => x.Reference).Order());
    Assert.Equal(["behind: GitHub has other work on this branch"], plan.Skipped);
    Assert.Equal(new HashSet<string> { "refs/heads/new", "refs/heads/main" },
      CodeBackupPlan.Accepted("To x\n*\tabc:refs/heads/new\t[new branch]\n+\tabc:refs/heads/f\tforced\n!\tabc:refs/heads/r\t[rejected]\n \tabc:refs/heads/main\ta..b\nDone\n"));
  }

  [Fact]
  public async Task UncommittedWorkIsBackedUpAndThePageSaysSo()
  {
    var github = NewGitHub();
    var repo = HomedRepo("notes", github);
    s.Write(repo, "README.md", "changed\n"); s.Write(repo, "draft.md", "draft\n");
    s.Write(repo, "x.txt", "set aside\n"); s.Git(repo, "add", "x.txt"); s.Git(repo, "stash", "-q");
    var sideBefore = s.HisSide(repo);
    var rig = MakeRig([P("notes", "Notes", repo)], github);
    var row = (await rig.Projects.Report(refresh: true)).Projects[0];
    Assert.Equal(CodeBackupState.FilesChanged, row.State);
    var outcome = await rig.Actions.BackUp("notes");
    Assert.True(outcome.Ok, outcome.Line);
    Assert.Equal(sideBefore, s.HisSide(repo));
    row = (await rig.Projects.Report(refresh: true)).Projects[0];
    Assert.Equal(CodeBackupState.BackedUp, row.State);
    Assert.NotNull(row.ChangesCoveredAt); Assert.True(row.SetAsideCovered);
    var then = new Clock().At.AddSeconds(60);
    Assert.Equal("Backed up", CodeBackupWords.Summary(row, then));
    Assert.StartsWith("Last backed up Today", CodeBackupWords.LastBackedUp(row, then));
    await Task.Delay(50);
    s.Write(repo, "draft.md", "draft, longer now\n");
    row = (await rig.Projects.Report(refresh: true)).Projects[0];
    Assert.Equal(CodeBackupState.FilesChanged, row.State);
    var before = s.Refs(github.Bare("fixture-owner/notes"))[Area + "work/main"];
    var again = await rig.Actions.BackUp("notes");
    Assert.True(again.Ok, again.Line);
    var after = s.Refs(github.Bare("fixture-owner/notes"))[Area + "work/main"];
    s.Git(github.Bare("fixture-owner/notes"), "merge-base", "--is-ancestor", before, after);
  }

  [Fact]
  public async Task ABranchWithASecretFileInItsCommitsStaysHere()
  {
    var github = NewGitHub();
    var repo = HomedRepo("keys", github);
    s.Git(repo, "checkout", "-q", "-b", "leaky");
    s.Write(repo, "config/server.pem", "-----BEGIN PRIVATE KEY-----\nMIIfixture\n-----END PRIVATE KEY-----\n");
    s.Git(repo, "add", "-A"); s.GitAt(repo, T2, "commit", "-q", "-m", "oops");
    s.Git(repo, "checkout", "-q", "-b", "certs", "main");
    s.Write(repo, "config/ca.pem", "-----BEGIN CERTIFICATE-----\nMIIfixture\n-----END CERTIFICATE-----\n");
    s.Git(repo, "add", "-A"); s.GitAt(repo, T2, "commit", "-q", "-m", "ca");
    s.Git(repo, "checkout", "-q", "main");
    var rig = MakeRig([P("keys", "Keys", repo)], github);
    var outcome = await rig.Actions.BackUp("keys");
    Assert.Contains("leaky: not sent: server.pem is in its commits", outcome.Line);
    var refs = s.Refs(github.Bare("fixture-owner/keys"));
    Assert.True(refs.ContainsKey(Area + "heads/certs"));
    Assert.False(refs.ContainsKey("refs/heads/leaky"));
    Assert.False(refs.ContainsKey(Area + "heads/leaky"));
  }

  // ---- a private home, only on his click ----

  [Fact]
  public async Task APrivateHomeIsMadeOnlyByTheClick()
  {
    var github = NewGitHub();
    github.Add("fixture-owner/my-app", true, "someone else's");
    var repo = s.Folder("my app"); s.Git(repo, "init", "-q"); s.Commit(repo, "main.cs", "start", T1);
    var clock = new Clock();
    var rig = MakeRig([P("app", "My App", repo)], github, clock: clock);
    await rig.Actions.Decorate(await rig.Projects.Report(refresh: true));
    for (var i = 0; i < 4; i++) { await rig.Actions.Look(); clock.Advance(600); }
    Assert.Empty(github.Created);
    var target = await rig.Actions.TargetOf("app");
    Assert.True(target?.NewHome); Assert.Equal("github.com/fixture-owner/my-app", target?.Address);
    var outcome = await rig.Actions.BackUp("app");
    Assert.True(outcome.Ok, outcome.Line);
    Assert.Equal(["fixture-owner/my-app-2"], github.Created);
    Assert.True(github.Named("fixture-owner/my-app-2")?.IsPrivate);
    Assert.Equal("https://github.com/fixture-owner/my-app-2.git", s.GitTrim(repo, "config", "--get", "remote.origin.url"));
    var refs = s.Refs(github.Bare("fixture-owner/my-app-2"));
    Assert.False(refs.ContainsKey("refs/heads/main"));
    Assert.True(refs.ContainsKey(Area + "heads/main"));
    Assert.Equal("fixture-owner/my-app-2", rig.Ledger.Home("app"));
  }

  [Fact]
  public async Task SomeoneElsesHomeIsWrittenOnlyWithPushAccess()
  {
    var github = NewGitHub();
    var repo = HomedRepo("shared", github);
    s.Git(repo, "remote", "set-url", "origin", "https://github.com/some-org/shared.git");
    github.Alias("some-org/shared", "fixture-owner/shared", canPush: false);
    s.Commit(repo, "b.txt", "mine", T2);
    var rig = MakeRig([P("shared", "Shared", repo)], github);
    var before = s.Refs(github.Bare("fixture-owner/shared"));
    var outcome = await rig.Actions.BackUp("shared");
    Assert.False(outcome.Ok);
    Assert.Contains("no permission to send to github.com/some-org/shared", outcome.Line);
    Assert.Equal(before, s.Refs(github.Bare("fixture-owner/shared")));
  }

  // ---- Automatic ----

  [Fact]
  public async Task AutomaticWaitsForWorkToSettleAndNeverDuringAGitOperation()
  {
    var github = NewGitHub();
    var repo = HomedRepo("auto", github);
    var bare = github.Bare("fixture-owner/auto");
    var clock = new Clock();
    var project = P("auto", "Auto", repo);
    var offline = MakeRig([project], github, clock: clock, network: false);
    s.Commit(repo, "a.txt", "work", T2);
    for (var i = 0; i < 3; i++) { await offline.Actions.Look(); clock.Advance(400); }
    var keeper = Area + "heads/main"; var realMain = s.Refs(bare)["refs/heads/main"];
    Assert.False(s.Refs(bare).ContainsKey(keeper));

    var rig = MakeRig([project], github, clock: clock);
    Assert.Equal(CodeBackupMode.Manual, (await rig.Actions.Decorate(await rig.Projects.Report(refresh: true))).Projects[0].Mode);
    rig.Ledger.SetFirstBackupDone();
    Assert.Equal(CodeBackupMode.Automatic, (await rig.Actions.Decorate(await rig.Projects.Report(refresh: true))).Projects[0].Mode);
    await rig.Actions.Look();
    clock.Advance(120); await rig.Actions.Look();
    Assert.False(s.Refs(bare).ContainsKey(keeper));
    s.Write(repo, "b.txt", "still typing\n");
    clock.Advance(240); await rig.Actions.Look();
    clock.Advance(240); await rig.Actions.Look();
    Assert.False(s.Refs(bare).ContainsKey(keeper));
    File.WriteAllBytes(Path.Combine(repo, ".git", "MERGE_HEAD"), []);
    for (var i = 0; i < 3; i++) { clock.Advance(400); await rig.Actions.Look(); }
    Assert.False(s.Refs(bare).ContainsKey(keeper));
    File.Delete(Path.Combine(repo, ".git", "MERGE_HEAD"));
    await rig.Actions.Look();
    clock.Advance(301); await rig.Actions.Look();
    Assert.Equal(s.GitTrim(repo, "rev-parse", "main"), s.GitTrim(bare, "rev-parse", s.Refs(bare)[keeper] + "^1"));
    Assert.True(s.Refs(bare).ContainsKey(Area + "work/main"));
    Assert.Equal(realMain, s.Refs(bare)["refs/heads/main"]);
    await rig.Actions.SetMode("auto", CodeBackupMode.Off);
    var kept = s.Refs(bare);
    s.Commit(repo, "c.txt", "more", T3);
    for (var i = 0; i < 4; i++) { clock.Advance(1_000); await rig.Actions.Look(); }
    Assert.Equal(kept, s.Refs(bare));
  }

  // ---- correction 14 Nov: a backup never writes his real branches or tags ----

  [Fact]
  public async Task CommitsKeptPrivatelyCountAsBackedUpAndSaySoHonestly()
  {
    var github = NewGitHub();
    var repo = HomedRepo("api", github);
    var bare = github.Bare("fixture-owner/api");
    s.Commit(repo, "a.txt", "second", T2); s.Commit(repo, "b.txt", "third", T3);
    var before = s.Refs(bare);
    var rig = MakeRig([P("api", "API", repo)], github);
    Assert.Equal(CodeBackupState.CommitsNotOnGitHub, (await rig.Projects.Report(refresh: true)).Projects[0].State);
    var outcome = await rig.Actions.BackUp("api");
    Assert.True(outcome.Ok, outcome.Line);
    Assert.Equal(before, s.Refs(bare).Where(r => !r.Key.StartsWith("refs/terminal-deck-backup/")).ToDictionary());
    var row = (await rig.Projects.Report(refresh: true)).Projects[0];
    Assert.Equal(CodeBackupState.BackedUp, row.State);
    Assert.Equal(0, row.CommitCount); Assert.Equal(2, row.PrivateCommitCount); Assert.Equal(["main"], row.PrivateBranches);
    Assert.Equal("Backed up · 2 commits not pushed to main: backed up privately", CodeBackupWords.Summary(row, DateTimeOffset.Now));
    Assert.False(row.OffersBackUp);
    var oldKeeper = s.Refs(bare)[Area + "heads/main"];
    s.GitAt(repo, T3, "commit", "-q", "--amend", "-m", "third, reworded");
    var again = await rig.Actions.BackUp("api");
    Assert.True(again.Ok, again.Line);
    var newKeeper = s.Refs(bare)[Area + "heads/main"];
    Assert.NotEqual(oldKeeper, newKeeper);
    s.Git(bare, "merge-base", "--is-ancestor", oldKeeper, newKeeper);
    Assert.Equal(s.GitTrim(repo, "rev-parse", "main"), s.GitTrim(bare, "rev-parse", newKeeper + "^1"));
  }

  [Fact]
  public async Task AHomeTerminalDeckMadeAlsoGetsOnlyPrivateReferences()
  {
    var github = NewGitHub();
    var repo = s.Folder("site"); s.Git(repo, "init", "-q"); s.Commit(repo, "index.html", "hello", T1); s.Git(repo, "tag", "v1");
    var rig = MakeRig([P("site", "Site", repo)], github);
    var first = await rig.Actions.BackUp("site");
    Assert.True(first.Ok, first.Line);
    var bare = github.Bare("fixture-owner/site");
    Assert.False(CodeBackupPlan.RealNamesAllowed);
    Assert.All(s.Refs(bare).Keys, k => Assert.StartsWith(Area, k));
    Assert.True(s.Refs(bare).ContainsKey(Area + "heads/main"));
    Assert.True(s.Refs(bare).ContainsKey(Area + "tags/v1"));
    s.Git(repo, "checkout", "-q", "-b", "feature"); s.Commit(repo, "f.html", "feature", T3);
    var second = await rig.Actions.BackUp("site");
    Assert.True(second.Ok, second.Line);
    Assert.All(s.Refs(bare).Keys, k => Assert.StartsWith(Area, k));
    Assert.True(s.Refs(bare).ContainsKey(Area + "heads/feature"));
    // Get the code from a home holding only private references, on another device.
    var hooked = NewGitHub(Path.Combine(s.Root, "second"));
    var plain = s.Folder("plain"); s.Git(plain, "init", "-q"); s.Commit(plain, "a.txt", "a", T1);
    var rig2 = MakeRig([P("plain", "Plain", plain)], hooked);
    var made = await rig2.Actions.BackUp("plain");
    Assert.True(made.Ok, made.Line);
    Assert.False(s.Refs(hooked.Bare("fixture-owner/plain")).ContainsKey("refs/heads/main"));
    Assert.True(s.Refs(hooked.Bare("fixture-owner/plain")).ContainsKey(Area + "heads/main"));
    var folder = Path.Combine(s.Home, "Terminal Deck", "Projects", "Plain"); Directory.CreateDirectory(folder);
    s.Write(folder, "CLAUDE.md", "rules\n");
    var other = MakeRig([P("plain", "Plain", folder)], hooked, made: [folder]);
    var got = await other.Actions.GetCode("plain");
    Assert.True(got.Ok, got.Line);
    Assert.Equal("a\n", s.Read(folder, "a.txt"));
    Assert.Equal(s.GitTrim(plain, "rev-parse", "main"), s.GitTrim(folder, "rev-parse", "main"));
  }

  [Fact]
  public async Task APublicHomeGetsNothing()
  {
    var github = NewGitHub();
    var repo = HomedRepo("open", github, isPrivate: false);
    s.Commit(repo, "a.txt", "work", T2); s.Write(repo, "draft.md", "draft\n");
    var before = s.Refs(github.Bare("fixture-owner/open"));
    var rig = MakeRig([P("open", "Open", repo)], github);
    var outcome = await rig.Actions.BackUp("open");
    Assert.False(outcome.Ok);
    Assert.Contains("is public; backups go only to a private home", outcome.Line);
    Assert.Equal(before, s.Refs(github.Bare("fixture-owner/open")));
  }

  // ---- Get the code ----

  [Fact]
  public async Task GetTheCodeKeepsInstructionFilesResumesAndNeverOverwrites()
  {
    var github = NewGitHub();
    var source = HomedRepo("shop", github);
    s.Write(source, "CLAUDE.md", "from GitHub\n"); s.Write(source, "AGENTS.md", "same\n"); s.Write(source, "src/a.txt", "code\n");
    s.Git(source, "add", "-A"); s.GitAt(source, T2, "commit", "-q", "-m", "code");
    s.Git(source, "push", "-q", github.Bare("fixture-owner/shop"), "main:refs/heads/main");
    var folder = Path.Combine(s.Home, "Terminal Deck", "Projects", "Shop"); Directory.CreateDirectory(folder);
    s.Write(folder, "CLAUDE.md", "mine, different\n"); s.Write(folder, "AGENTS.md", "same\n");
    var project = P("shop", "Shop", folder);
    var first = MakeRig([project], github, made: [folder], git: new FailingOnce(s.Runner(), "checkout"));
    var row = (await first.Actions.Decorate(await first.Projects.Report(refresh: true))).Projects[0];
    Assert.Equal(CodeBackupState.CodeNotHere, row.State); Assert.Equal("fixture-owner/shop", row.GetFrom);
    var stopped = await first.Actions.GetCode("shop");
    Assert.False(stopped.Ok);
    Assert.NotNull(first.Ledger.Getting("shop"));
    Assert.Equal("mine, different\n", s.Read(folder, "CLAUDE.md"));
    Assert.False(Directory.Exists(Path.Combine(folder, ".git")));
    row = (await first.Actions.Decorate(await first.Projects.Report(refresh: true))).Projects[0];
    Assert.True(row.Getting); Assert.Equal(CodeBackupState.CodeNotHere, row.State);
    var done = await first.Actions.GetCode("shop");
    Assert.True(done.Ok, done.Line);
    Assert.Contains("kept your CLAUDE.md (it differs from GitHub's)", done.Line);
    Assert.Equal("mine, different\n", s.Read(folder, "CLAUDE.md"));
    Assert.Equal("same\n", s.Read(folder, "AGENTS.md"));
    Assert.Equal("code\n", s.Read(folder, "src/a.txt"));
    Assert.False(Directory.Exists(CodeBackupGetCode.Temporary(folder)));
    Assert.Null(first.Ledger.Getting("shop"));
    row = (await first.Actions.Decorate(await first.Projects.Report(refresh: true))).Projects[0];
    Assert.True(row.IsRepository); Assert.Equal("main", row.Branch); Assert.Equal("fixture-owner/shop", row.Home);
    Assert.Equal(["CLAUDE.md"], row.ChangedFiles);
  }

  [Fact]
  public async Task GetTheCodeThenThePageSaysBackedUp()
  {
    var github = NewGitHub();
    var source = HomedRepo("blog", github);
    s.Write(source, "CLAUDE.md", "rules\n"); s.Git(source, "add", "-A"); s.GitAt(source, T2, "commit", "-q", "-m", "rules");
    s.Git(source, "push", "-q", github.Bare("fixture-owner/blog"), "main:refs/heads/main");
    var folder = Path.Combine(s.Home, "Terminal Deck", "Projects", "Blog"); Directory.CreateDirectory(folder);
    s.Write(folder, "CLAUDE.md", "rules\n");
    var rig = MakeRig([P("blog", "Blog", folder)], github, made: [folder]);
    var done = await rig.Actions.GetCode("blog");
    Assert.True(done.Ok, done.Line); Assert.Equal("Code is here · branch main", done.Line);
    var row = (await rig.Projects.Report(refresh: true)).Projects[0];
    Assert.Equal(CodeBackupState.BackedUp, row.State); Assert.Equal("main", row.Branch);
  }

  // ---- the repository above a project folder is never touched ----

  [Fact]
  public async Task ARepositoryAboveTheFolderIsNeverTouched()
  {
    var github = NewGitHub();
    var home = s.Home;
    s.Git(home, "init", "-q"); s.Commit(home, ".zshrc", "home", T1);
    s.Write(home, "Documents/Tracked/notes.txt", "tracked by home\n"); s.Git(home, "add", "-A"); s.GitAt(home, T2, "commit", "-q", "-m", "docs");
    var homeGit = CodeBackupScratch.Snapshot(Path.Combine(home, ".git"));
    var waiting = Path.Combine(home, "Terminal Deck", "Projects", "Site"); Directory.CreateDirectory(waiting);
    s.Write(waiting, "CLAUDE.md", "rules\n");
    var tracked = Path.Combine(home, "Documents", "Tracked");
    var plain = Path.Combine(home, "Documents", "Plain");
    s.Write(plain, "idea.txt", "his own folder\n");
    var siteBare = github.Add("fixture-owner/site", true);
    var siteSource = s.Folder("site-source"); s.Git(siteSource, "init", "-q"); s.Commit(siteSource, "index.html", "site", T1);
    s.Git(siteSource, "push", "-q", siteBare, "main:refs/heads/main");
    var rig = MakeRig([P("site", "Site", waiting), P("tracked", "Tracked", tracked), P("home", "Home", home), P("plain", "Plain", plain)], github, made: [waiting]);
    var notHere = await rig.Actions.BackUp("site");
    Assert.False(notHere.Ok); Assert.Equal("Code not on this PC yet", notHere.Line);
    Assert.False((await rig.Actions.BackUp("tracked")).Ok);
    Assert.False((await rig.Actions.BackUp("home")).Ok);
    for (var i = 0; i < 3; i++) await rig.Actions.Look();
    Assert.Equal(homeGit, CodeBackupScratch.Snapshot(Path.Combine(home, ".git")));
    Assert.False(Directory.Exists(Path.Combine(tracked, ".git")));
    var plainBackup = await rig.Actions.BackUp("plain");
    Assert.True(plainBackup.Ok, plainBackup.Line);
    Assert.True(Directory.Exists(Path.Combine(plain, ".git")));
    var got = await rig.Actions.GetCode("site");
    Assert.True(got.Ok, got.Line);
    Assert.Equal(homeGit, CodeBackupScratch.Snapshot(Path.Combine(home, ".git")));
    Assert.Equal(["fixture-owner/plain"], github.Created);
  }

  // ---- review 14 Nov ----

  [Fact]
  public async Task ATagAndASetAsideChangeCarryingASecretAreHeldBackAndNamed()
  {
    var github = NewGitHub();
    var tagged = HomedRepo("tagged", github);
    s.Git(tagged, "checkout", "-q", "-b", "tmp"); s.Commit(tagged, ".env", "TOKEN=fixture", T2);
    s.Git(tagged, "tag", "leak"); s.Git(tagged, "checkout", "-q", "main"); s.Git(tagged, "branch", "-q", "-D", "tmp");
    var stashed = HomedRepo("stashed", github);
    s.Write(stashed, "README.md", "clean change\n"); s.Git(stashed, "stash", "-q");
    var clean = s.GitTrim(stashed, "rev-parse", "refs/stash");
    s.Write(stashed, "config/.ENV", "TOKEN=fixture\n"); s.Git(stashed, "stash", "push", "-u", "-q");
    var secret = s.GitTrim(stashed, "rev-parse", "refs/stash");
    var rig = MakeRig([P("tagged", "Tagged", tagged), P("stashed", "Stashed", stashed)], github);
    var tagOutcome = await rig.Actions.BackUp("tagged");
    Assert.Contains("tag leak: not sent: .env is in its commits", tagOutcome.Line);
    Assert.False(s.Refs(github.Bare("fixture-owner/tagged")).ContainsKey(Area + "tags/leak"));
    var stashOutcome = await rig.Actions.BackUp("stashed");
    Assert.Contains("not sent: .ENV is in it", stashOutcome.Line);
    var setAside = s.Refs(github.Bare("fixture-owner/stashed"))[Area + "set-aside"];
    var parents = s.Git(github.Bare("fixture-owner/stashed"), "rev-list", "--parents", "-n", "1", setAside);
    Assert.Contains(clean, parents);
    Assert.DoesNotContain(secret, parents);
    Assert.Throws<InvalidOperationException>(() => s.Git(github.Bare("fixture-owner/stashed"), "cat-file", "-e", secret + "^{commit}"));
  }

  [Fact]
  public void TheSecretKindsMatchInAnyCase()
  {
    foreach (var name in new[] { ".env", "a/.env.local", ".env.development.local", "release.keystore", "keys/AuthKey_ABC123.p8", "ID_ECDSA", "deploy/credentials", "infra/terraform.tfstate", "vault.kdbx", ".git-credentials", "service-account-prod.json", ".dev.vars", "home/.ssh/config" })
    {
      Assert.Equal(CodeBackupReader.SecretKind.Credential, CodeBackupReader.KindOf(name));
      Assert.True(CodeBackupReader.IsSecret(name), name); Assert.True(CodeBackupReader.HoldsBack(name), name);
    }
    foreach (var name in new[] { "ios/GoogleService-Info.plist", "android/app/google-services.json", ".env.production", ".env.example", "app/DEBUG.KEYSTORE", ".npmrc", ".yarnrc.yml", ".envrc", "infra/prod.tfvars", "certs/Dist.MobileProvision" })
    {
      Assert.Equal(CodeBackupReader.SecretKind.LeaveOut, CodeBackupReader.KindOf(name));
      Assert.True(CodeBackupReader.IsSecret(name), name); Assert.False(CodeBackupReader.HoldsBack(name), name);
    }
    foreach (var name in new[] { "x/server.PEM", "talk.key", "KEYS.asc" }) Assert.Equal(CodeBackupReader.SecretKind.MaybeKey, CodeBackupReader.KindOf(name));
    Assert.True(CodeBackupReader.PrivateKey("-----BEGIN RSA PRIVATE KEY-----\nMII\n"u8));
    Assert.True(CodeBackupReader.PrivateKey("-----BEGIN PGP PRIVATE KEY BLOCK-----\n"u8));
    Assert.False(CodeBackupReader.PrivateKey("-----BEGIN CERTIFICATE-----\nMII\n"u8));
    Assert.False(CodeBackupReader.PrivateKey("-----BEGIN PGP PUBLIC KEY BLOCK-----\n"u8));
    foreach (var name in new[] { "README.md", "id_rsa.pub", "src/credentials.swift", "keystore.md", "Config/Release.xcconfig" }) Assert.Equal(CodeBackupReader.SecretKind.None, CodeBackupReader.KindOf(name));
  }

  [Fact]
  public async Task OnlyRealCredentialsHoldBackABranch()
  {
    var github = NewGitHub();
    var repo = HomedRepo("mobile", github);
    var baseCommit = s.GitTrim(repo, "rev-parse", "main");
    s.Git(repo, "checkout", "-q", "-b", "firebase"); s.Commit(repo, "ios/GoogleService-Info.plist", "plist", T2);
    s.Commit(repo, "android/debug.keystore", "debug", T2);
    s.Git(repo, "checkout", "-q", "-b", "release", baseCommit); s.Commit(repo, "android/release.keystore", "release", T2);
    s.Git(repo, "checkout", "-q", "main");
    s.Write(repo, ".env.production", "PUBLIC_URL=x\n"); s.Write(repo, "draft.md", "draft\n");
    var rig = MakeRig([P("mobile", "Mobile", repo)], github);
    var outcome = await rig.Actions.BackUp("mobile");
    Assert.True(outcome.Ok, outcome.Line);
    var bare = github.Bare("fixture-owner/mobile");
    Assert.True(s.Refs(bare).ContainsKey(Area + "heads/firebase"));
    Assert.False(s.Refs(bare).ContainsKey(Area + "heads/release"));
    Assert.Contains("release: not sent: release.keystore is in its commits", outcome.Line);
    Assert.Contains("1 file left out", outcome.Line);
    var work = s.Refs(bare)[Area + "work/main"];
    Assert.Equal("draft\n", s.Git(bare, "show", work + ":draft.md"));
    Assert.Throws<InvalidOperationException>(() => s.Git(bare, "show", work + ":.env.production"));
  }

  [Fact]
  public async Task TheLeaveOutListIsWrittenOnlyInsideAGitTheAppMade()
  {
    var github = NewGitHub();
    var plain = s.Folder("plain");
    s.Write(plain, "a.txt", "mine\n"); s.Write(plain, ".env", "TOKEN=fixture\n"); s.Write(plain, "node_modules/x/index.js", "big\n");
    var his = HomedRepo("his", github);
    var hisExclude = s.Read(his, ".git/info/exclude");
    var rig = MakeRig([P("plain", "Plain", plain), P("his", "His", his)], github);
    var made = await rig.Actions.BackUp("plain");
    Assert.True(made.Ok, made.Line);
    Assert.Contains("1 file left out (secret files)", made.Line);
    Assert.StartsWith(CodeBackupReader.ExcludeMarker, s.Read(plain, ".git/info/exclude"));
    Assert.Null(s.Read(plain, ".gitignore"));
    var work = s.Refs(github.Bare("fixture-owner/plain"))[Area + "work/main"];
    Assert.Equal("a.txt", s.GitTrim(github.Bare("fixture-owner/plain"), "ls-tree", "-r", "--name-only", work));
    var again = await rig.Actions.BackUp("his");
    Assert.True(again.Ok, again.Line);
    Assert.Equal(hisExclude, s.Read(his, ".git/info/exclude"));
  }

  [Fact]
  public async Task ANestedOrganisationRepositoryGetsNothing()
  {
    var github = NewGitHub();
    var repo = HomedRepo("app", github);
    s.Write(repo, ".gitignore", "lib/\n"); s.Git(repo, "add", "-A"); s.GitAt(repo, T2, "commit", "-q", "-m", "ignore");
    var orgBare = github.Add("some-org/lib", true);
    var lib = Path.Combine(repo, "lib"); Directory.CreateDirectory(lib);
    s.Git(lib, "init", "-q"); s.Commit(lib, "lib.txt", "org code", T1);
    s.Git(lib, "remote", "add", "origin", "https://github.com/some-org/lib.git");
    s.Write(lib, "wip.txt", "his uncommitted work\n");
    var before = s.Refs(orgBare);
    var rig = MakeRig([P("app", "App", repo)], github);
    var outcome = await rig.Actions.BackUp("app");
    Assert.True(outcome.Ok, outcome.Line);
    Assert.Contains("github.com/some-org/lib is not on your account; not backed up", outcome.Line);
    Assert.Equal(before, s.Refs(orgBare));
  }

  [Fact]
  public async Task GetTheCodeFromOnlyUncommittedBackupsPlacesTheFilesAndFromNothingFailsHonestly()
  {
    var github = NewGitHub();
    var draft = s.Folder("draft"); s.Write(draft, "notes.txt", "never committed\n");
    var first = MakeRig([P("draft", "Draft", draft)], github);
    var backedUp = await first.Actions.BackUp("draft");
    Assert.True(backedUp.Ok, backedUp.Line);
    Assert.All(s.Refs(github.Bare("fixture-owner/draft")).Keys, k => Assert.Contains("/work/", k));
    var folder = Path.Combine(s.Home, "Terminal Deck", "Projects", "Draft");
    s.Write(folder, "CLAUDE.md", "rules\n");
    var second = MakeRig([P("draft", "Draft", folder)], github, made: [folder]);
    var got = await second.Actions.GetCode("draft");
    Assert.True(got.Ok, got.Line);
    Assert.Equal("never committed\n", s.Read(folder, "notes.txt"));
    Assert.Equal("rules\n", s.Read(folder, "CLAUDE.md"));
    github.Add("fixture-owner/empty", true);
    var emptyFolder = Path.Combine(s.Home, "Terminal Deck", "Projects", "Empty");
    s.Write(emptyFolder, "CLAUDE.md", "rules\n");
    var third = MakeRig([P("empty", "Empty", emptyFolder)], github, made: [emptyFolder]);
    var nothing = await third.Actions.GetCode("empty");
    Assert.False(nothing.Ok);
    Assert.Equal("Code not got: GitHub has no code for this project yet", nothing.Line);
    Assert.False(Directory.Exists(Path.Combine(emptyFolder, ".git")));
    Assert.Null(third.Ledger.Getting("empty"));
    Assert.False(Directory.Exists(CodeBackupGetCode.Temporary(emptyFolder)));
  }

  [Fact]
  public async Task ManualUntilTheFirstBackUpNowThenAutomaticButNeverOverHisChoice()
  {
    var github = NewGitHub();
    var eligible = HomedRepo("eligible", github); var pinned = HomedRepo("pinned", github);
    var clock = new Clock();
    var rig = MakeRig([P("eligible", "Eligible", eligible), P("pinned", "Pinned", pinned)], github, clock: clock);
    var report = await rig.Actions.Decorate(await rig.Projects.Report(refresh: true));
    Assert.True(report.AutomaticWaits);
    Assert.All(report.Projects, p => Assert.Equal(CodeBackupMode.Manual, p.Mode));
    s.Commit(eligible, "a.txt", "work", T2);
    for (var i = 0; i < 4; i++) { await rig.Actions.Look(); clock.Advance(400); }
    Assert.All(s.Refs(github.Bare("fixture-owner/eligible")).Keys, k => Assert.False(k.StartsWith("refs/terminal-deck-backup/")));
    await rig.Actions.SetMode("pinned", CodeBackupMode.Manual);
    var first = await rig.Actions.BackUp("pinned", byHand: true);
    Assert.True(first.Ok, first.Line);
    Assert.True(rig.Ledger.FirstBackupDone);
    report = await rig.Actions.Decorate(await rig.Projects.Report(refresh: true));
    Assert.False(report.AutomaticWaits);
    Assert.Equal(CodeBackupMode.Automatic, report.Projects.First(p => p.Id == "eligible").Mode);
    Assert.Equal(CodeBackupMode.Manual, report.Projects.First(p => p.Id == "pinned").Mode);
  }

  [Fact]
  public void TwoComputersWithTheSameNameDoNotShareABackupArea()
  {
    var a = CodeBackupActions.ComputerPart("Studio", CodeBackupActions.DeviceId("11111111-AAAA-4AAA-8AAA-111111111111"));
    var b = CodeBackupActions.ComputerPart("Studio", CodeBackupActions.DeviceId("22222222-BBBB-4BBB-8BBB-222222222222"));
    Assert.NotEqual(a, b);
    Assert.True(a.StartsWith("Studio-") && b.StartsWith("Studio-"));
    Assert.DoesNotContain("11111111", a);
    Assert.Equal(a, CodeBackupPlan.Part(a));
    Assert.Equal(a, CodeBackupActions.ComputerPart("Studio", CodeBackupActions.DeviceId("11111111-aaaa-4aaa-8aaa-111111111111")));
  }

  // ---- last review fixes, 14 Nov ----

  [Fact]
  public async Task ABackUpThroughAToolNeverSwitchesOnAutomatic()
  {
    var github = NewGitHub();
    var repo = HomedRepo("tooled", github);
    s.Commit(repo, "a.txt", "work", T2);
    var rig = MakeRig([P("tooled", "Tooled", repo)], github);
    var viaTool = await rig.Actions.BackUp("tooled");
    Assert.True(viaTool.Ok, viaTool.Line);
    Assert.False(rig.Ledger.FirstBackupDone);
    await rig.Actions.SetMode("tooled", CodeBackupMode.Automatic);
    Assert.False(rig.Ledger.FirstBackupDone);
    Assert.Equal(CodeBackupMode.Automatic, rig.Ledger.Mode("tooled"));
    var byHand = await rig.Actions.BackUp("tooled", byHand: true);
    Assert.True(byHand.Ok, byHand.Line);
    Assert.True(rig.Ledger.FirstBackupDone);
  }

  [Fact]
  public async Task AMergeThatAddsASecretIsHeldBack()
  {
    var github = NewGitHub();
    var repo = HomedRepo("merged", github);
    s.Git(repo, "checkout", "-q", "-b", "side"); s.Commit(repo, "side.txt", "side", T2); s.Git(repo, "checkout", "-q", "main");
    s.Commit(repo, "main.txt", "main", T2);
    s.Git(repo, "merge", "--no-ff", "--no-commit", "-q", "side");
    s.Write(repo, ".env", "TOKEN=fixture\n"); s.Git(repo, "add", "-A"); s.GitAt(repo, T3, "commit", "-q", "-m", "merge");
    s.Git(repo, "branch", "-q", "-D", "side");
    var rig = MakeRig([P("merged", "Merged", repo)], github);
    var outcome = await rig.Actions.BackUp("merged");
    Assert.Contains("main: not sent: .env is in its commits", outcome.Line);
    Assert.False(s.Refs(github.Bare("fixture-owner/merged")).ContainsKey(Area + "heads/main"));
  }

  [Fact]
  public async Task AnOrganisationHomeIsBackUpNowOnly()
  {
    var github = NewGitHub();
    var repo = HomedRepo("team", github);
    s.Git(repo, "remote", "set-url", "origin", "https://github.com/some-org/team.git");
    github.Alias("some-org/team", "fixture-owner/team", canPush: true);
    s.Commit(repo, "a.txt", "work", T2);
    var bare = github.Bare("fixture-owner/team");
    var clock = new Clock();
    var rig = MakeRig([P("team", "Team", repo)], github, clock: clock);
    rig.Ledger.SetFirstBackupDone(); rig.Ledger.SetMode("team", CodeBackupMode.Automatic);
    var before = s.Refs(bare);
    for (var i = 0; i < 4; i++) { await rig.Actions.Look(); clock.Advance(400); }
    Assert.Equal(before, s.Refs(bare));
    var row = (await rig.Actions.Decorate(await rig.Projects.Report(refresh: true))).Projects[0];
    Assert.Equal(CodeBackupMode.Manual, row.Mode);
    Assert.Equal([CodeBackupMode.Manual, CodeBackupMode.Off], row.ModeChoices);
    Assert.Equal("Home: some-org/team (organisation): Back up now only; everyone in some-org can see backups", CodeBackupWords.HomeLine(row));
    await rig.Actions.SetMode("team", CodeBackupMode.Automatic);
    Assert.Equal(CodeBackupMode.Manual, rig.Ledger.Mode("team"));
    Assert.Equal("some-org", (await rig.Actions.TargetOf("team"))?.Organisation);
    var manual = await rig.Actions.BackUp("team", byHand: true);
    Assert.True(manual.Ok, manual.Line);
    Assert.True(s.Refs(bare).ContainsKey(Area + "heads/main"));
  }

  [Fact]
  public async Task HisOwnExcludeIsLeftAloneWhenGitAppearsBeforeTheAppsInit()
  {
    var github = NewGitHub();
    var folder = s.Folder("racing"); s.Write(folder, "a.txt", "mine\n");
    var his = "# his own\n*.log\n";
    var runner = new BeforeInit(s.Runner(), cwd =>
    {
      if (!string.Equals(Path.GetFullPath(cwd), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase) || Directory.Exists(Path.Combine(folder, ".git"))) return;
      s.Git(folder, "init", "-q");
      s.Write(folder, ".git/info/exclude", his);
    });
    var rig = MakeRig([P("racing", "Racing", folder)], github, git: runner);
    await rig.Actions.BackUp("racing");
    Assert.Equal(his, s.Read(folder, ".git/info/exclude"));
    var fresh = Path.Combine(s.Root, "fresh", ".git");
    s.Write(fresh, "info/exclude", "# git ls-files --others --exclude-from=.git/info/exclude\n# *~\n");
    Assert.True(CodeBackupActions.WriteExclude(fresh));
    Assert.StartsWith(CodeBackupReader.ExcludeMarker, s.Read(fresh, "info/exclude"));
  }

  [Fact]
  public void MatchingAHomeForGetTheCode()
  {
    CodeBackupRepo[] repos = [new("org/my-site", true, true), new("me/my-site", true, true), new("org/tools", false, false)];
    Assert.Equal("me/my-site", CodeBackupActions.Match("My Site", repos, "me"));
    Assert.Equal("org/tools", CodeBackupActions.Match("Tools", repos, "me"));
    Assert.Null(CodeBackupActions.Match("Nope", repos, "me"));
    Assert.Equal("deck-dev-mac-new", CodeBackupNames.Repository("Deck Dev / Mac (new)!"));
    Assert.Equal("project", CodeBackupNames.Repository("🙂"));
    Assert.Equal("lane--code-page", CodeBackupPlan.Part("lane/code page"));
  }
}
