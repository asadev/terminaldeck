using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Code;

/// Port of the Mac's CodeBackupTakeCodeTests ("Switch to this PC", the code half) on SCRATCH repositories only: a local
/// bare repository stands in for GitHub, the old computer's backup references are written there as its Code backup writes
/// them. Nothing is pushed anywhere else.
public sealed class CodeBackupTakeCodeTests : IDisposable
{
  private readonly CodeBackupScratch s = new();
  public void Dispose() => s.Dispose();
  private string Bare => Path.Combine(s.Root, "github.git");
  private string Air => Path.Combine(s.Root, "air");
  private const string Area = "refs/terminal-deck-backup/MacBook-Air-abcd1234/";
  private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_794_700_000);

  /// GitHub has `main` at c1. The old computer committed c2 on top (backed up as a keeper) and has uncommitted work
  /// (backed up as a work copy).
  private (string Keeper, string Work, string Tip) OldComputerBackedUp(string? tracked = null, string? unsaved = null)
  {
    Directory.CreateDirectory(Bare); s.Git(Bare, "init", "-q", "--bare");
    Directory.CreateDirectory(Air); s.Git(Air, "init", "-q");
    s.Write(Air, "a.txt", "one\n"); s.Git(Air, "add", "-A"); s.Git(Air, "commit", "-q", "-m", "c1");
    s.Git(Air, "push", "-q", Bare, "main:refs/heads/main");
    s.Write(Air, "c.txt", "two\n");
    if (tracked is not null) s.Write(Air, tracked, "the old Mac's " + tracked + "\n");
    s.Git(Air, "add", "-A"); s.Git(Air, "commit", "-q", "-m", "c2");
    var tip = s.GitTrim(Air, "rev-parse", "HEAD");
    var keeper = s.GitTrim(Air, "commit-tree", tip + "^{tree}", "-p", tip, "-m", "Branch main on MacBook-Air (Terminal Deck backup)");
    s.Write(Air, "c.txt", "two, and more not saved yet\n");
    if (unsaved is not null) { s.Write(Air, unsaved, "the old Mac's " + unsaved + "\n"); s.Git(Air, "add", "--", unsaved); }
    var work = s.GitTrim(Air, "stash", "create");
    if (unsaved is not null) s.Git(Air, "reset", "-q");
    s.Git(Air, "push", "-q", Bare, keeper + ":" + Area + "heads/main", work + ":" + Area + "work/main");
    return (keeper, work, tip);
  }
  private string Clone(string name)
  {
    var folder = Path.Combine(s.Root, name);
    s.Git(s.Root, "clone", "-q", Bare, folder);
    s.Git(folder, "remote", "set-url", "origin", "https://github.com/fixture-owner/site.git");
    return folder;
  }
  private CodeBackupTransport Transport => new(Bare, CodeBackupGitRunner.Settings([("protocol.file.allow", "always")]));
  private async Task<CodeBackupTakeCode.Result> Take(string folder, CodeBackupTakeCode.Named named, CodeBackupTakeCode.Pending? pending = null, List<CodeBackupTakeCode.Pending?>? journal = null, ICodeBackupGit? git = null) =>
    await new CodeBackupTakeCode(git ?? s.Runner(), Transport, "https://github.com/fixture-owner/site.git", folder, "fixture-owner/site", now: Now, pending: pending,
      record: value => { journal?.Add(value); return Task.CompletedTask; }).Perform(named);
  private static CodeBackupTakeCode.Named Named((string Keeper, string Work, string Tip) old) => new("main", old.Keeper, old.Work, "MacBook Air", 1);
  private void Ignore(string folder, string name) => s.Write(folder, ".git/info/exclude", name + "\n");
  private string? StashRef(string folder, string message) =>
    s.Git(folder, "stash", "list", "--format=%gd%x09%gs").Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(l => l.TrimEnd().EndsWith(message, StringComparison.Ordinal))?.Split('\t')[0];

  /// Git as the switch runs it, with one file written into the folder during the switch: just before the first step after
  /// its stash and its check.
  private sealed class WritesDuringSwitch(ICodeBackupGit inner, string file) : ICodeBackupGit
  {
    private bool stashed, written;
    public async Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default)
    {
      if (stashed && !written && arguments.Count > 0 && arguments[0] is not ("status" or "stash")) { written = true; File.WriteAllText(file, "written by an editor during the switch\n"); }
      var outcome = await inner.RunAsync(cwd, arguments, environment, timeoutMilliseconds, maximumBytes, ct);
      if (arguments.Count > 1 && arguments[0] == "stash" && arguments[1] == "push" && arguments.Any(a => a.StartsWith("Terminal Deck: kept before switch", StringComparison.Ordinal))) stashed = true;
      return outcome;
    }
  }

  [Fact]
  public async Task OwnChangesArePutAsideAndRecoverable()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    s.Write(mini, "a.txt", "mine, not saved\n"); s.Write(mini, "notes.txt", "only here\n");
    var result = await Take(mini, Named(old));
    Assert.Equal(CodeBackupTakeCode.Kind.FastForward, result.Kind);
    Assert.Equal(old.Tip, s.GitTrim(mini, "rev-parse", "HEAD"));
    Assert.Equal("main", s.GitTrim(mini, "symbolic-ref", "--short", "HEAD"));
    Assert.Equal("two, and more not saved yet\n", s.Read(mini, "c.txt"));
    Assert.Equal("one\n", s.Read(mini, "a.txt"));
    var kept = Assert.IsType<string>(result.KeptAside);
    Assert.StartsWith("Terminal Deck: kept before switch ", kept);
    Assert.Contains(kept, s.Git(mini, "stash", "list"));
    s.Git(mini, "checkout", "-q", "--", ".");
    s.Git(mini, "stash", "apply", "-q");
    Assert.Equal("mine, not saved\n", s.Read(mini, "a.txt"));
    Assert.Equal("only here\n", s.Read(mini, "notes.txt"));
  }

  [Fact]
  public async Task SplitHistoriesKeepBoth()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    s.Write(mini, "m.txt", "this PC's own work\n"); s.Git(mini, "add", "-A"); s.Git(mini, "commit", "-q", "-m", "mine");
    var mine = s.GitTrim(mini, "rev-parse", "HEAD");
    var result = await Take(mini, Named(old));
    Assert.Equal(CodeBackupTakeCode.Kind.OwnBranch, result.Kind); Assert.Equal("main-MacBook-Air", result.Branch);
    Assert.Equal(mine, s.GitTrim(mini, "rev-parse", "refs/heads/main"));
    Assert.Equal(old.Tip, s.GitTrim(mini, "rev-parse", "refs/heads/main-MacBook-Air"));
    Assert.Equal("main-MacBook-Air", s.GitTrim(mini, "symbolic-ref", "--short", "HEAD"));
    Assert.Equal("two, and more not saved yet\n", s.Read(mini, "c.txt"));
    Assert.Null(result.KeptAside);
  }

  [Fact]
  public async Task MissingFolderIsMadeAndGetsTheCode()
  {
    var old = OldComputerBackedUp();
    var folder = Path.Combine(s.Root, "Projects", "site");
    Assert.False(Directory.Exists(folder));
    var result = await Take(folder, Named(old));
    Assert.Equal(CodeBackupTakeCode.Kind.GotCode, result.Kind);
    Assert.True(Directory.Exists(Path.Combine(folder, ".git")));
    Assert.Equal(old.Tip, s.GitTrim(folder, "rev-parse", "HEAD"));
    Assert.Equal("two, and more not saved yet\n", s.Read(folder, "c.txt"));
  }

  [Fact]
  public async Task TakenWithoutHandOverUsesTheNewestBackup()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    var result = await Take(mini, new(null, null, null, "MacBook Air", null));
    Assert.Equal(CodeBackupTakeCode.Kind.FastForward, result.Kind);
    Assert.Equal(old.Tip, s.GitTrim(mini, "rev-parse", "HEAD"));
    Assert.NotNull(result.CodeAt);
  }

  [Fact]
  public async Task IgnoredFileThatWouldBeWrittenOverIsKeptAndNamed()
  {
    var old = OldComputerBackedUp(unsaved: ".env.local");
    var mini = Clone("mini");
    Ignore(mini, ".env.local");
    s.Write(mini, ".env.local", "this PC's own secret\n");
    var result = await Take(mini, Named(old));
    Assert.Equal(CodeBackupTakeCode.Kind.FastForward, result.Kind);
    Assert.Equal([".env.local"], result.KeptIgnored);
    var folder = Assert.IsType<string>(result.KeptIgnoredFolder);
    Assert.Contains(Path.Combine("terminal-deck-switch", "kept-"), folder);
    Assert.Equal("this PC's own secret\n", s.Read(folder, ".env.local"));
    Assert.Equal("the old Mac's .env.local\n", s.Read(mini, ".env.local"));
    Assert.Null(result.KeptAside);
  }

  [Fact]
  public async Task FailureAfterTheStashPutsHisChangesBack()
  {
    var old = OldComputerBackedUp(tracked: "build.cfg");
    var mini = Clone("mini");
    var before = s.GitTrim(mini, "rev-parse", "HEAD");
    Ignore(mini, "build.cfg");
    s.Write(mini, "build.cfg", "this PC's own build settings\n");
    s.Write(mini, "a.txt", "mine, not saved\n");
    var journal = new List<CodeBackupTakeCode.Pending?>();
    var result = await Take(mini, Named(old), journal: journal);
    Assert.Equal(CodeBackupTakeCode.Kind.Failed, result.Kind);
    Assert.Contains("Your unsaved changes here are back as they were.", result.Failure);
    Assert.Equal("mine, not saved\n", s.Read(mini, "a.txt"));
    Assert.Equal("this PC's own build settings\n", s.Read(mini, "build.cfg"));
    Assert.Equal(before, s.GitTrim(mini, "rev-parse", "HEAD"));
    Assert.Equal("", s.GitTrim(mini, "stash", "list"));
    Assert.Null(result.KeptAside);
    Assert.NotNull(journal.First());
    Assert.Null(journal.Last());
  }

  [Fact]
  public async Task FileWrittenDuringAFailingLiveSwitchIsKept()
  {
    var old = OldComputerBackedUp(tracked: "build.cfg");
    var mini = Clone("mini");
    Ignore(mini, "build.cfg");
    s.Write(mini, "build.cfg", "this PC's own build settings\n");
    s.Write(mini, "a.txt", "mine, not saved\n");
    var result = await Take(mini, Named(old), git: new WritesDuringSwitch(s.Runner(), Path.Combine(mini, "autosave.txt")));
    Assert.Equal(CodeBackupTakeCode.Kind.Failed, result.Kind);
    Assert.Contains("Your unsaved changes here are back as they were.", result.Failure);
    Assert.Contains("Files changed here during the switch are kept as 'Terminal Deck: your edits made during a stopped switch, ", result.Failure);
    Assert.Equal("mine, not saved\n", s.Read(mini, "a.txt"));
    Assert.Equal("this PC's own build settings\n", s.Read(mini, "build.cfg"));
    var reference = Assert.IsType<string>(StashRef(mini, "Terminal Deck: your edits made during a stopped switch, " + CodeBackupTakeCode.Stamp(Now)));
    s.Git(mini, "checkout", "-q", "--", ".");
    s.Git(mini, "stash", "apply", "-q", reference);
    Assert.Equal("written by an editor during the switch\n", s.Read(mini, "autosave.txt"));
  }

  [Fact]
  public async Task InterruptedAfterTheStashIsUndoneAndReported()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    var head = s.GitTrim(mini, "rev-parse", "HEAD");
    s.Write(mini, "a.txt", "mine, not saved\n");
    const string message = "Terminal Deck: kept before switch earlier";
    s.Git(mini, "stash", "push", "--include-untracked", "-m", message);
    var result = await Take(mini, Named(old), new(message, head, "main", 1_794_699_000_000));
    Assert.Equal(CodeBackupTakeCode.Kind.FastForward, result.Kind);
    Assert.Contains("stopped half-way", result.Resumed);
    Assert.DoesNotContain(message, s.Git(mini, "stash", "list"));
    var kept = Assert.IsType<string>(result.KeptAside);
    Assert.Contains(kept, s.Git(mini, "stash", "list"));
    s.Git(mini, "checkout", "-q", "--", ".");
    s.Git(mini, "stash", "apply", "-q");
    Assert.Equal("mine, not saved\n", s.Read(mini, "a.txt"));
  }

  [Fact]
  public async Task FolderOfAnotherProjectIsRefused()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    s.Git(mini, "remote", "set-url", "origin", "https://github.com/someone/other.git");
    s.Write(mini, "a.txt", "mine, not saved\n");
    var before = s.GitTrim(mini, "rev-parse", "HEAD");
    var result = await Take(mini, Named(old));
    Assert.Equal(CodeBackupTakeCode.Kind.OtherProject, result.Kind);
    Assert.Equal("This folder belongs to another project, so the code was not changed.", CodeBackupTakeCode.RefusedOtherProject);
    Assert.Equal("mine, not saved\n", s.Read(mini, "a.txt"));
    Assert.Equal(before, s.GitTrim(mini, "rev-parse", "HEAD"));
    Assert.Equal("", s.GitTrim(mini, "stash", "list"));
  }

  [Fact]
  public async Task StaleLockIsNamed()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    var lockFile = Path.Combine(mini, ".git", "index.lock");
    File.WriteAllBytes(lockFile, []);
    File.SetLastWriteTimeUtc(lockFile, Now.AddSeconds(-3_600).UtcDateTime);
    var result = await Take(mini, Named(old));
    Assert.Equal(CodeBackupTakeCode.Kind.Failed, result.Kind);
    Assert.StartsWith("Git left a lock file behind in this project (.git/index.lock, from ", result.Failure);
    Assert.True(File.Exists(lockFile));
  }

  [Fact]
  public async Task EditsMadeDuringAStoppedSwitchAreKeptBeforeTheUndo()
  {
    var old = OldComputerBackedUp();
    var mini = Clone("mini");
    var head = s.GitTrim(mini, "rev-parse", "HEAD");
    s.Write(mini, "a.txt", "mine, not saved\n");
    const string message = "Terminal Deck: kept before switch earlier";
    s.Git(mini, "stash", "push", "--include-untracked", "-m", message);
    s.Write(mini, "a.txt", "edited while it was stopped\n");
    s.Write(mini, "new.txt", "added while it was stopped\n");
    var result = await Take(mini, Named(old), new(message, head, "main", 1_794_699_000_000));
    Assert.Equal(CodeBackupTakeCode.Kind.FastForward, result.Kind);
    var resumed = Assert.IsType<string>(result.Resumed);
    Assert.Contains("You changed files here while the switch was stopped; those changes are kept as 'Terminal Deck: your edits made during a stopped switch, ", resumed);
    var kept = Assert.IsType<string>(result.KeptAside);
    var keptRef = Assert.IsType<string>(StashRef(mini, kept));
    s.Git(mini, "checkout", "-q", "--", ".");
    s.Git(mini, "stash", "apply", "-q", keptRef);
    Assert.Equal("mine, not saved\n", s.Read(mini, "a.txt"));
    s.Git(mini, "checkout", "-q", "--", ".");
    var editsRef = Assert.IsType<string>(StashRef(mini, "Terminal Deck: your edits made during a stopped switch, " + CodeBackupTakeCode.Stamp(Now)));
    s.Git(mini, "stash", "apply", "-q", editsRef);
    Assert.Equal("edited while it was stopped\n", s.Read(mini, "a.txt"));
    Assert.Equal("added while it was stopped\n", s.Read(mini, "new.txt"));
    Assert.Null(StashRef(mini, message));
  }
}

/// Port of the Mac's MacTidyCodeBackupWordsTests (15 Nov): the rows say from which computer the last backup came and link
/// the GitHub repository by name. Pure values and an in-memory or scratch ledger only.
public sealed class CodeBackupWordsTests
{
  private static CodeBackupProject Row() => new("p1", "Notes") { HasFolder = true, IsRepository = true, Home = "someone/notes", Branch = "main" };

  [Fact]
  public void LastBackedUpNamesThisPcWhenItSentTheNewestBackup()
  {
    var now = DateTimeOffset.FromUnixTimeSeconds(1_794_000_000); var ms = now.ToUnixTimeMilliseconds();
    var row = Row(); row.LastBackedUpAt = ms - 3_600_000;
    Assert.False(CodeBackupWords.LastBackedUp(row, now, TimeZoneInfo.Utc).EndsWith(" from Studio PC", StringComparison.Ordinal));
    row.SentAt = ms - 600_000; row.SentFrom = "Studio PC";
    Assert.Equal("Last backed up " + CodeBackupWords.When(ms - 600_000, now, TimeZoneInfo.Utc) + " from Studio PC", CodeBackupWords.LastBackedUp(row, now, TimeZoneInfo.Utc));
    row.LastBackedUpAt = ms - 60_000;
    Assert.DoesNotContain(" from ", CodeBackupWords.LastBackedUp(row, now, TimeZoneInfo.Utc));
  }

  [Fact]
  public void TheRepositoryLinkIsItsGitHubPage()
  {
    Assert.Equal("https://github.com/someone/notes", CodeBackupActions.Link("github.com", "someone/notes"));
    Assert.Null(CodeBackupActions.Link("github.com", null));
    Assert.Null(CodeBackupActions.Link("github.com", "not-a-repository"));
  }

  [Fact]
  public void TheLedgerKeepsWhenThisPcSentAndReadsOlderFiles()
  {
    var folder = Path.Combine(Path.GetTempPath(), "code-backup-ledger-" + Guid.NewGuid().ToString("N")[..8]);
    Directory.CreateDirectory(folder);
    try
    {
      var file = Path.Combine(folder, CodeBackupLedger.FileName);
      File.WriteAllText(file, """{"modes":{"p1":"off"},"firstBackupDone":true}""");
      var old = new CodeBackupLedger(file);
      Assert.Equal(CodeBackupMode.Off, old.Mode("p1")); Assert.True(old.FirstBackupDone); Assert.Null(old.SentAt("p1"));
      old.SetSent("p1", 42);
      Assert.Equal(42, new CodeBackupLedger(file).SentAt("p1"));
      Assert.Equal(CodeBackupMode.Off, new CodeBackupLedger(file).Mode("p1"));
      Assert.Contains("\"off\"", File.ReadAllText(file));
    }
    finally { CodeBackupDisk.Delete(folder); }
  }

  [Fact]
  public void NotFoundOnGitHubIsPlainWords()
  {
    Assert.DoesNotContain("/", CodeBackupWords.NotFoundOnGitHub);
    Assert.Contains("Back up now", CodeBackupWords.NotFoundOnGitHub);
  }

  [Fact]
  public void ToolsKeepTheirNamesAndTiers()
  {
    Assert.Equal(["code.projects", "code.backup_now", "code.get_code", "code.set_mode"], CodeBackupTools.Specs.Select(t => t.Id));
    Assert.Equal(["code_projects", "code_backup_now", "code_get_code", "code_set_mode"], CodeBackupTools.Specs.Select(t => t.Wire));
    Assert.Equal(TerminalDeck.Core.Mcp.McpTier.Read, CodeBackupTools.Specs[0].Tier);
    Assert.All(CodeBackupTools.Specs.Skip(1), t => Assert.Equal(TerminalDeck.Core.Mcp.McpTier.Alter, t.Tier));
    var transport = CodeBackupTransport.Https("github.com", "o/n", "ghp_fixturefixturefixturefixture1234");
    Assert.DoesNotContain("ghp_", transport.Url);
    Assert.Equal("fatal: [hidden] refused", transport.Scrub("fatal: ghp_fixturefixturefixturefixture1234 refused"));
    Assert.Equal("", transport.Environment["GIT_CONFIG_VALUE_0"]);
  }
}
