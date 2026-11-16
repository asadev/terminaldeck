namespace TerminalDeck.Core.Code;

/// "Get the code" (port of the Mac's BackendCodeBackupGetCode, owner 14 Nov: only by his click, into the project's folder).
/// The project's folder may already hold instruction files from his Cloud, and Git will not download into a folder that
/// holds files, so:
/// 1. the code is downloaded into a folder BESIDE the project's folder (`.<folder>.terminal-deck-download`), a little
///    history at a time (`--depth`, then `--deepen`), so a download cut off continues where it stopped;
/// 2. the branch is checked out there;
/// 3. every file is MOVED into the project's folder where nothing is in the way; a file already there with the same bytes
///    stays as it is; a file already there with DIFFERENT bytes is KEPT (his) and GitHub's copy is not placed;
/// 4. Git's own folder moves in LAST, so the folder never looks like a repository with files missing.
public sealed class CodeBackupGetCode(ICodeBackupGit git, CodeBackupTransport transport, string homeUrl, string folder, string temporary, Action<string>? progress = null)
{
  public sealed class Failure(string plain, bool final = false) : Exception(plain)
  {
    public string Plain { get; } = plain;
    /// True when trying again cannot help (GitHub holds no code): the half-made download is dropped.
    public bool Final { get; } = final;
  }
  public const string Suffix = ".terminal-deck-download";
  public static string Temporary(string folder)
  {
    folder = Path.TrimEndingDirectorySeparator(folder);
    return Path.Combine(Path.GetDirectoryName(folder) ?? folder, "." + Path.GetFileName(folder) + Suffix);
  }
  /// Git LFS is never run: its large files stay as Git's small pointer files, and the line says so.
  public static readonly IReadOnlyDictionary<string, string> NoLfs = new Dictionary<string, string> { ["GIT_LFS_SKIP_SMUDGE"] = "1" };

  private readonly Action<string> say = progress ?? (_ => { });
  private async Task<CodeProcessResult> Run(IReadOnlyList<string> arguments, bool network = false, int timeout = 120_000, IReadOnlyDictionary<string, string>? extra = null)
  {
    var environment = CodeBackupGitRunner.Merge(network ? transport.Environment : new Dictionary<string, string>(), extra ?? new Dictionary<string, string>());
    var outcome = await git.RunAsync(temporary, arguments, environment, timeout, 8 * 1024 * 1024);
    if (outcome.Missing) throw new Failure("Git is not installed on this PC");
    return outcome;
  }
  private string Line(CodeProcessResult outcome)
  {
    var last = transport.Scrub(outcome.Error).Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? "";
    return last[..Math.Min(160, last.Length)];
  }
  private static bool Lfs(string attributes)
  {
    try { return File.Exists(attributes) && File.ReadAllText(attributes).Contains("filter=lfs", StringComparison.Ordinal); }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }

  /// The branch now on this PC, the files of his that were kept because they differ from GitHub's, and whether the code
  /// keeps large files with Git LFS (not included).
  public async Task<(string? Branch, IReadOnlyList<string> Kept, bool Large)> Perform()
  {
    if (!Directory.Exists(folder)) throw new Failure("The project's folder is not on this PC");
    if (CodeBackupDisk.Exists(Path.Combine(folder, ".git")))
    {
      // A run that stopped right after Git's folder moved in: only the clean-up is left.
      CodeBackupDisk.Delete(temporary);
      return (null, [], Lfs(Path.Combine(folder, ".gitattributes")));
    }
    if (!CodeBackupDisk.Exists(Path.Combine(temporary, ".git")))
    {
      try { Directory.CreateDirectory(temporary); }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new Failure("A folder for the download could not be made beside the project's folder"); }
      var made = await Run(["init", "-q"]);
      if (!made.Ok) throw new Failure("Git could not start the download");
      await Run(["remote", "add", "origin", homeUrl]);
    }
    say("Getting the code · asking GitHub");
    var listing = await Run(["ls-remote", "--symref", "--", transport.Url], network: true);
    if (!listing.Ok) throw new Failure("GitHub did not answer (" + Line(listing) + ")");
    var rows = listing.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(r => r.TrimEnd('\r')).ToList();
    var branch = rows.Where(r => r.StartsWith("ref: refs/heads/", StringComparison.Ordinal) && r.EndsWith("\tHEAD", StringComparison.Ordinal))
      .Select(r => r["ref: refs/heads/".Length..r.IndexOf('\t')]).FirstOrDefault();
    var empty = !rows.Any(r => r.Contains("\trefs/heads/", StringComparison.Ordinal) || r.Contains("\trefs/tags/", StringComparison.Ordinal));
    List<(string Reference, string Branch)> Backed(string kind) => rows.Select(r => r.Split('\t', 2)).Where(p => p.Length == 2 && p[1].StartsWith(CodeBackupPlan.Namespace, StringComparison.Ordinal) && p[1].Contains(kind, StringComparison.Ordinal))
      .Select(p => (p[1], p[1][(p[1].IndexOf(kind, StringComparison.Ordinal) + kind.Length)..])).ToList();
    var keepers = Backed("/heads/");
    var work = Backed("/work/");
    string[] refspecs = ["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/" + CodeBackupPlan.Prefix + "*", "refs/tags/*:refs/tags/*"];
    var shallow = Path.Combine(temporary, ".git", "shallow");
    var started = await Run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + (branch ?? "main")]);
    if (!started.Ok && !empty)
    {
      say("Getting the code · downloading");
      var first = await Run(["fetch", "--quiet", "--depth=50", "--no-write-fetch-head", "--", transport.Url, .. refspecs], network: true, timeout: 600_000);
      if (!first.Ok) throw new Failure("The download stopped (" + Line(first) + "). Get the code again to continue");
    }
    for (var step = 1; File.Exists(shallow) && step <= 400; step++)
    {
      say("Getting the code · downloading history (" + step + ")");
      var more = await Run(["fetch", "--quiet", "--deepen=2000", "--no-write-fetch-head", "--", transport.Url, .. refspecs], network: true, timeout: 600_000);
      if (!more.Ok) throw new Failure("The download stopped (" + Line(more) + "). Get the code again to continue");
      if ((await Run(["rev-parse", "--is-shallow-repository"])).Output.Trim() == "false") break;
    }
    // The branch to open: GitHub's own, else main, else the first one (never a backup branch).
    var known = await Run(["for-each-ref", "--format=%(refname:strip=3)", "refs/remotes/origin"]);
    var remoteBranches = known.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(b => b.Trim()).Where(b => b != "HEAD" && !b.StartsWith(CodeBackupPlan.Prefix, StringComparison.Ordinal)).ToList();
    if (branch is null || !remoteBranches.Contains(branch)) branch = remoteBranches.Contains("main") ? "main" : remoteBranches.Contains("master") ? "master" : remoteBranches.FirstOrDefault();
    var opened = (await Run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])).Ok;
    var placedWork = false;
    async Task<(string Sha, string Branch, long At)?> Newest(IReadOnlyList<(string Reference, string Branch)> entries)
    {
      (string, string, long)? newest = null;
      foreach (var entry in entries)
      {
        var sha = rows.FirstOrDefault(r => r.EndsWith("\t" + entry.Reference, StringComparison.Ordinal))?.Split('\t')[0];
        if (sha is null) continue;
        var at = long.TryParse((await Run(["log", "-1", "--format=%ct", sha])).Output.Trim(), out var seconds) ? seconds : 0;
        if (newest is null || at > newest.Value.Item3) newest = (sha, entry.Branch, at);
      }
      return newest;
    }
    if (branch is null && keepers.Count == 0 && !opened && work.Count > 0)
    {
      // No branch anywhere: the newest copy of uncommitted work, opened as files on a new branch with no commits yet.
      say("Getting the code · downloading the backup");
      var got = await Run(["fetch", "--quiet", "--no-write-fetch-head", "--no-tags", "--", transport.Url, .. work.Select(w => w.Reference)], network: true, timeout: 600_000);
      if (!got.Ok) throw new Failure("The download stopped (" + Line(got) + "). Get the code again to continue");
      if (await Newest(work) is { } newest)
      {
        var name = newest.Branch == "no-branch" ? "main" : newest.Branch;
        say("Getting the code · opening " + name);
        var pointed = await Run(["symbolic-ref", "HEAD", "refs/heads/" + name]);
        var read = await Run(["read-tree", "--reset", "-u", newest.Sha + "^{tree}"], timeout: 600_000, extra: NoLfs);
        if (!pointed.Ok || !read.Ok) throw new Failure("The files could not be opened (" + Line(read.Ok ? pointed : read) + ")");
        branch = name; placedWork = true;
      }
    }
    else if (branch is null && keepers.Count > 0 && !opened)
    {
      // No real branch on GitHub: open his newest backed-up branch (main first) as a plain local branch.
      say("Getting the code · downloading the backup");
      var wanted = keepers.Any(k => k.Branch == "main") ? keepers.Where(k => k.Branch == "main").ToList() : keepers;
      var got = await Run(["fetch", "--quiet", "--no-write-fetch-head", "--no-tags", "--", transport.Url, .. wanted.Select(w => w.Reference)], network: true, timeout: 600_000);
      if (!got.Ok) throw new Failure("The download stopped (" + Line(got) + "). Get the code again to continue");
      if (await Newest(wanted) is { } newest)
      {
        say("Getting the code · opening " + newest.Branch);
        var checkout = await Run(["checkout", "-q", "-b", newest.Branch, newest.Sha + "^1"], timeout: 600_000, extra: NoLfs);
        if (!checkout.Ok) throw new Failure("The files could not be opened (" + Line(checkout) + ")");
        branch = newest.Branch;
      }
    }
    else if (branch is not null && !(await Run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch])).Ok)
    {
      say("Getting the code · opening " + branch);
      var checkout = await Run(["checkout", "-q", "-b", branch, "--track", "origin/" + branch], timeout: 600_000, extra: NoLfs);
      if (!checkout.Ok) throw new Failure("The files could not be opened (" + Line(checkout) + ")");
    }
    // Never "Code is here" with nothing placed.
    var hasCommit = (await Run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])).Ok;
    if (!placedWork && !hasCommit) throw new Failure("Code not got: GitHub has no code for this project yet", final: true);
    var large = Lfs(Path.Combine(temporary, ".gitattributes"));
    say("Getting the code · placing files");
    var kept = new List<string>();
    Merge(temporary, folder, "", kept);
    try { Directory.Move(Path.Combine(temporary, ".git"), Path.Combine(folder, ".git")); }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new Failure("Git's folder could not be moved into the project's folder"); }
    CodeBackupDisk.Delete(temporary);
    return (branch, kept.Order(StringComparer.Ordinal).ToList(), large);
  }

  /// Moves `source` into `target` without ever replacing anything there (Git's own folder is left for last).
  public static void Merge(string source, string target, string relative, List<string> kept)
  {
    IEnumerable<string> entries;
    try { entries = Directory.EnumerateFileSystemEntries(source).ToList(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return; }
    foreach (var from in entries)
    {
      var name = Path.GetFileName(from);
      if (relative.Length == 0 && name == ".git") continue;
      var to = Path.Combine(target, name); var path = relative.Length == 0 ? name : relative + "/" + name;
      var theirs = Kind(from);
      if (theirs == EntryKind.None) continue;
      var mine = Kind(to);
      if (mine == EntryKind.None)
      {
        // Exclusive: a file that appears at the same instant is never replaced; it is then his.
        try
        {
          if (theirs == EntryKind.Folder) Directory.Move(from, to); else File.Move(from, to, overwrite: false);
          continue;
        }
        catch (IOException) when (Kind(to) != EntryKind.None) { mine = Kind(to); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new Failure("A file could not be placed (" + path + ")"); }
      }
      if (mine == EntryKind.Folder && theirs == EntryKind.Folder) Merge(from, to, path, kept);
      else if (mine == EntryKind.File && theirs == EntryKind.File) { if (!Same(from, to)) kept.Add(path); }
      else if (mine == EntryKind.Link && theirs == EntryKind.Link && new FileInfo(from).LinkTarget == new FileInfo(to).LinkTarget) continue;
      else kept.Add(path);
    }
  }

  private enum EntryKind { None, File, Folder, Link }
  private static EntryKind Kind(string path)
  {
    try
    {
      var info = new FileInfo(path);
      if (info.LinkTarget is not null) return EntryKind.Link;
      if (info.Exists) return EntryKind.File;
      return Directory.Exists(path) ? (new DirectoryInfo(path).LinkTarget is not null ? EntryKind.Link : EntryKind.Folder) : EntryKind.None;
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return EntryKind.None; }
  }
  private static bool Same(string a, string b)
  {
    try
    {
      var left = new FileInfo(a); var right = new FileInfo(b);
      if (left.Length != right.Length) return false;
      using var x = File.OpenRead(a); using var y = File.OpenRead(b);
      var bx = new byte[65536]; var by = new byte[65536];
      while (true)
      {
        var n = x.ReadAtLeast(bx, bx.Length, throwOnEndOfStream: false); var m = y.ReadAtLeast(by, by.Length, throwOnEndOfStream: false);
        if (n != m || !bx.AsSpan(0, n).SequenceEqual(by.AsSpan(0, m))) return false;
        if (n == 0) return true;
      }
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }
}
