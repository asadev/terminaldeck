using System.Globalization;

namespace TerminalDeck.Core.Code;

/// What the old computer's hand-over names for its code (the Mac's BackendCloudSessionMove.CodeHandOver).
public sealed record CodeBackupHandOver(bool Ok, long? CodeAt, string? Branch, string? HeadSha, string? WorkSha);

/// "Switch to this PC", the code half (port of the Mac's BackendCodeBackupTakeCode, owner 15 Nov): the old computer's code,
/// exactly as its hand-over backup named it, laid into this PC's project folder. Never loses work:
/// - his own unsaved changes here are put aside in Git (`git stash push -u -m "Terminal Deck: kept before switch <time>"`)
///   BEFORE any file changes; when they cannot be put aside, nothing changes at all;
/// - his branch is moved only forward; with split histories the old computer's commit goes on a branch of its own
///   (`<branch>-<computer>`) and his branch stays exactly where it was;
/// - the old computer's uncommitted work is laid over the files without removing any; files Git ignores here are copied
///   first, never overwritten without a copy;
/// - no project folder or no code yet: Get the code first (it keeps any file already there).
/// Only references under `refs/terminal-deck-switch/` are added for the fetched commits; nothing is pushed anywhere.
public sealed class CodeBackupTakeCode
{
  /// What the old computer named, or for a take without one only its name (its newest backup is used).
  public sealed record Named(string? Branch, string? HeadSha, string? WorkSha, string FromComputer, long? CodeAt);
  public enum Kind { FastForward, OwnBranch, GotCode, NotConnected, NothingBackedUp, OtherProject, Failed }
  public sealed class Result(Kind kind, string? branch = null)
  {
    public Kind Kind { get; set; } = kind;
    /// The branch the code is on (for OwnBranch, the new branch); the reason for Failed is in Failure.
    public string? Branch { get; set; } = branch;
    public string? Failure { get; set; }
    public string? KeptAside { get; set; }
    public string? BringBack { get; set; }
    public string? KeptIgnoredFolder { get; set; }
    public List<string> KeptIgnored { get; set; } = [];
    public string? Resumed { get; set; }
    public long? CodeAt { get; set; }
    public bool IsFailure => Kind == Kind.Failed;
    public static Result Failed(string why) => new(Kind.Failed) { Failure = why };
  }
  /// Written into the move's journal BEFORE his changes are put aside, cleared when the switch is over.
  public sealed record Pending(string Stash, string Head, string? Branch, long At)
  {
    public string? Moved { get; set; }
    public string? Laid { get; set; }
  }
  private sealed class Failure(string plain, string? keptAside = null, string? bringBack = null, bool laidIn = false) : Exception(plain)
  {
    public string Plain { get; } = plain;
    public string? KeptAside { get; } = keptAside;
    public string? BringBack { get; } = bringBack;
    public bool LaidIn { get; } = laidIn;
  }
  public const string RefusedOtherProject = "This folder belongs to another project, so the code was not changed.";
  public const string LocalNamespace = "refs/terminal-deck-switch/";

  private readonly ICodeBackupGit git;
  private readonly CodeBackupTransport transport;
  private readonly string homeUrl, folder, home, host;
  private readonly DateTimeOffset now;
  private readonly Pending? pending;
  private readonly Func<Pending?, Task> record;
  private readonly Action<string> progress;

  public CodeBackupTakeCode(ICodeBackupGit git, CodeBackupTransport transport, string homeUrl, string folder, string home, string host = "github.com",
    DateTimeOffset? now = null, Pending? pending = null, Func<Pending?, Task>? record = null, Action<string>? progress = null)
  {
    this.git = git; this.transport = transport; this.homeUrl = homeUrl; this.folder = folder; this.home = home; this.host = host;
    this.now = now ?? DateTimeOffset.Now; this.pending = pending; this.record = record ?? (_ => Task.CompletedTask); this.progress = progress ?? (_ => { });
  }

  private async Task<CodeProcessResult> Run(IReadOnlyList<string> arguments, bool network = false, int timeout = 120_000, IReadOnlyDictionary<string, string>? extra = null)
  {
    var environment = CodeBackupGitRunner.Merge(network ? transport.Environment : CodeBackupGetCode.NoLfs, extra ?? new Dictionary<string, string>());
    var outcome = await git.RunAsync(folder, arguments, environment, timeout, 16 * 1024 * 1024);
    if (outcome.Missing) throw new Failure("Git is not installed on this PC");
    return outcome;
  }
  private static string Text(CodeProcessResult outcome) => outcome.Output.Trim();
  private string Line(CodeProcessResult outcome)
  {
    var last = transport.Scrub(outcome.Error).Split('\n').Select(l => l.TrimEnd('\r')).LastOrDefault(l => l.Length > 0) ?? "";
    return last[..Math.Min(160, last.Length)];
  }

  public async Task<Result> Perform(Named named)
  {
    try { return await Body(named); }
    catch (Failure failure) { return new(Kind.Failed) { Failure = failure.Plain, KeptAside = failure.KeptAside, BringBack = failure.BringBack }; }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { return Result.Failed("Git could not be started"); }
  }

  private async Task<string?> Parent(string commit)
  {
    var read = await Run(["rev-parse", "--verify", "--quiet", commit + "^1"]);
    return read.Ok ? Text(read) : null;
  }

  private async Task<Result> Body(Named named)
  {
    var got = false;
    // 0. No folder, or no code in it: made, then Get the code (which keeps every file already there).
    Directory.CreateDirectory(folder);
    if (!CodeBackupDisk.Exists(Path.Combine(folder, ".git")))
    {
      progress("Getting the code");
      try
      {
        await new CodeBackupGetCode(git, transport, homeUrl, folder, CodeBackupGetCode.Temporary(folder), progress).Perform();
        got = true;
      }
      catch (CodeBackupGetCode.Failure failure)
      {
        if (failure.Final) return new(Kind.NothingBackedUp);
        throw new Failure(failure.Plain);
      }
    }
    // 0b. Only the project's own repository: one of its remotes must name the GitHub home.
    if (!got)
    {
      var remotes = await Run(["config", "--get-regexp", @"^remote\..*\.url$"]);
      var homes = CodeBackupReader.Remotes(remotes.Output).Select(r => CodeBackupReader.GitHubHome(r.Url, host)?.ToLowerInvariant()).OfType<string>();
      if (!homes.Contains(home.ToLowerInvariant())) return new(Kind.OtherProject);
    }
    var gitDir = await GitDirectory();
    if (CodeBackupSend.GitBusy(gitDir) is { } busy)
    {
      // A lock file left by a Git that was stopped: named in plain words, never removed here.
      var lockFile = Path.Combine(gitDir, "index.lock");
      if (busy == "a Git command" && File.Exists(lockFile) && (now - new DateTimeOffset(File.GetLastWriteTimeUtc(lockFile), TimeSpan.Zero)).TotalSeconds > 120)
        throw new Failure("Git left a lock file behind in this project (.git/index.lock, from " + Stamp(new DateTimeOffset(File.GetLastWriteTimeUtc(lockFile), TimeSpan.Zero).ToOffset(now.Offset)) + ") and nothing was changed. "
          + "Close any Git app using this folder, delete that file, then switch again");
      throw new Failure("Git is in the middle of " + busy + " here");
    }
    // 0c. A switch stopped half-way before: undone cleanly first, then this one runs.
    string? resumed = null;
    if (pending is not null) resumed = await UndoInterrupted(pending);

    // 1. What GitHub holds: the refs the hand-over named, or (taken while the old computer was off) its newest backup.
    var listing = await Run(["ls-remote", "--", transport.Url], network: true);
    if (!listing.Ok) throw new Failure("GitHub did not answer (" + Line(listing) + ")");
    var remote = listing.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(r => r.TrimEnd('\r').Split('\t', 2))
      .Where(p => p.Length == 2 && !p[1].EndsWith("^{}", StringComparison.Ordinal)).Select(p => (Sha: p[0], Ref: p[1])).ToList();
    (string Sha, string Ref)? head = null, work = null;
    if (named.HeadSha is { } headSha)
    {
      var matches = remote.Where(r => r.Sha == headSha).ToList();
      var inArea = matches.Where(r => r.Ref.StartsWith(CodeBackupPlan.Namespace, StringComparison.Ordinal)).ToList();
      if (matches.Count > 0) head = inArea.Count > 0 ? inArea[0] : matches[0];
    }
    if (named.WorkSha is { } workSha)
    {
      var copies = remote.Where(r => r.Sha == workSha && r.Ref.StartsWith(CodeBackupPlan.Namespace, StringComparison.Ordinal)).ToList();
      if (copies.Count > 0) work = copies[0];
    }
    var forced = named.HeadSha is null && named.WorkSha is null;
    var fromPart = CodeBackupPlan.Part(named.FromComputer);
    var areaPrefix = CodeBackupPlan.Namespace + CodeBackupPlan.Part(fromPart[..Math.Min(60, fromPart.Length)]) + "-";
    var candidates = forced ? remote.Where(r => r.Ref.StartsWith(areaPrefix, StringComparison.Ordinal) && (r.Ref.Contains("/heads/") || r.Ref.Contains("/work/"))).ToList() : [];
    var wanted = forced ? candidates : new[] { head, work }.Where(x => x is not null).Select(x => x!.Value).ToList();
    if (wanted.Count == 0 && (forced || named.HeadSha is null)) return new(got ? Kind.GotCode : Kind.NothingBackedUp);

    // 2. Their commits into this repository under its own private names (nothing of his is moved by a fetch).
    if (wanted.Count > 0)
    {
      progress("Getting the code from " + named.FromComputer);
      var specs = wanted.Select((item, index) => "+" + item.Ref + ":" + LocalNamespace + index.ToString(CultureInfo.InvariantCulture)).ToList();
      var fetched = await Run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--", transport.Url, .. specs], network: true, timeout: 600_000);
      if (!fetched.Ok) throw new Failure("The code could not be downloaded (" + Line(fetched) + ")");
    }
    if (!forced && head is null && named.HeadSha is { } plainHead)
    {
      // His branch's own commit, already on one of GitHub's branches: fetched with them.
      var fetched = await Run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", transport.Url, "+refs/heads/*:" + LocalNamespace + "heads/*"], network: true, timeout: 600_000);
      if (!fetched.Ok || !(await Run(["cat-file", "-e", plainHead + "^{commit}"])).Ok) throw new Failure("The code " + named.FromComputer + " backed up is not on GitHub");
    }

    // 3. Which commit his branch should be at, and the work copy on top of it.
    string? tip = null, workCommit = null; var branch = named.Branch; var codeAt = named.CodeAt;
    if (forced)
    {
      (string Sha, string Ref, long At)? newest = null;
      foreach (var item in candidates)
      {
        var at = long.TryParse(Text(await Run(["log", "-1", "--format=%ct", item.Sha])), out var seconds) ? seconds : 0;
        if (newest is null || at > newest.Value.At) newest = (item.Sha, item.Ref, at);
      }
      if (newest is not { } found) return new(got ? Kind.GotCode : Kind.NothingBackedUp);
      codeAt ??= found.At * 1000;
      var isWork = found.Ref.Contains("/work/");
      if (isWork) workCommit = found.Sha;
      tip = await Parent(found.Sha);
      if (branch is null)
      {
        var marker = isWork ? "/work/" : "/heads/";
        var part = found.Ref[(found.Ref.IndexOf(marker, StringComparison.Ordinal) + marker.Length)..];
        branch = part == "no-branch" ? null : part.Replace("--", "/");
      }
    }
    else
    {
      if (head is { } h && named.HeadSha is { } sha) tip = h.Ref.StartsWith(CodeBackupPlan.Namespace, StringComparison.Ordinal) && h.Ref.Contains("/heads/") ? await Parent(sha) : sha;
      else if (named.HeadSha is { } plain) tip = plain;
      if (work is not null && named.WorkSha is { } workSha2) { workCommit = workSha2; tip ??= await Parent(workSha2); }
    }

    // 4. His own unsaved changes here are put aside in Git first. The journal knows the stash's name and his commit BEFORE
    //    it is made; from then on every way out either puts them back exactly or names where they are.
    string? kept = null;
    var status = await Run(["status", "--porcelain=v1", "--untracked-files=all"]);
    if (!status.Ok) throw new Failure("Git could not read the folder");
    var startRead = await Run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]);
    var currentRead = await Run(["symbolic-ref", "--quiet", "--short", "HEAD"]);
    var plan = new Pending("Terminal Deck: kept before switch " + Stamp(now), Text(startRead), currentRead.Ok ? Text(currentRead) : null, now.ToUnixTimeMilliseconds());
    if (Text(status).Length > 0)
    {
      await record(plan);
      var stashed = await Run(["stash", "push", "--include-untracked", "-m", plan.Stash], extra: await Identity());
      if (await StashRef(plan.Stash) is null)
      {
        await record(null);
        throw new Failure("your unsaved changes here could not be put aside (" + Line(stashed) + "), so nothing was changed");
      }
      kept = plan.Stash;
      var after = await Run(["status", "--porcelain=v1", "--untracked-files=all"]);
      if (!after.Ok || Text(after).Length > 0)
        throw await FailAfterStash(new Failure("Git could not put all of your unsaved changes here aside, so the code was not changed"), plan, partly: true);
    }
    try
    {
      var result = await LayIn(named, tip, workCommit, branch, got, plan, kept is not null);
      await record(null);
      result.KeptAside = kept; result.CodeAt = codeAt; result.Resumed = resumed;
      return result;
    }
    catch (Failure failure) when (kept is not null) { throw await FailAfterStash(failure, plan); }
    catch (Exception error) when (kept is not null && error is IOException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException)
    {
      throw await FailAfterStash(new Failure("the switch was stopped"), plan);
    }
  }

  /// Steps 5 and 6, after the stash.
  private async Task<Result> LayIn(Named named, string? tip, string? workCommit, string? branch, bool got, Pending plan, bool stashed)
  {
    // 5. The branch: forward only; split histories on a branch of its own.
    var kind = got ? Kind.GotCode : Kind.FastForward;
    string? target = null;
    if (tip is not null)
    {
      var current = await Run(["symbolic-ref", "--quiet", "--short", "HEAD"]);
      var name = branch ?? (current.Ok ? Text(current) : "main");
      var mine = await Run(["rev-parse", "--verify", "--quiet", "refs/heads/" + name]);
      if (!mine.Ok)
      {
        if (!(await Run(["branch", "--no-track", name, tip])).Ok) throw new Failure("the branch " + name + " could not be made");
        target = name;
      }
      else if (Text(mine) == tip || (await Run(["merge-base", "--is-ancestor", Text(mine), tip])).ExitCode == 0) target = name;
      else
      {
        // His branch has commits the old computer's does not: it stays exactly as it is.
        var own = name + "-" + CodeBackupPlan.Part(named.FromComputer);
        for (var index = 2; ; index++)
        {
          var there = await Run(["rev-parse", "--verify", "--quiet", "refs/heads/" + own]);
          if (!there.Ok) { if (!(await Run(["branch", "--no-track", own, tip])).Ok) throw new Failure("a branch could not be made"); break; }
          if (Text(there) == tip) break;
          own = name + "-" + CodeBackupPlan.Part(named.FromComputer) + "-" + index.ToString(CultureInfo.InvariantCulture);
        }
        target = own; kind = Kind.OwnBranch;
      }
      var checkout = await Run(["checkout", "-q", "--no-overwrite-ignore", target], timeout: 600_000);
      if (!checkout.Ok) throw new Failure("the branch " + target + " could not be opened (" + Line(checkout) + ")");
      if (kind != Kind.OwnBranch)
      {
        if (stashed) { plan.Moved = target; await record(plan); }
        var forward = await Run(["merge", "--ff-only", "--no-overwrite-ignore", "-q", tip], timeout: 600_000);
        if (!forward.Ok) throw new Failure("the branch " + target + " could not be moved forward (" + Line(forward) + ")");
      }
    }

    // 6. The old computer's uncommitted work over the files (adds and changes only; nothing removed). A file it would
    //    write over that is on disk but not tracked here can only be one Git ignores here: copied first, and named.
    var result = new Result(kind, target);
    if (workCommit is not null && tip is not null && await Parent(workCommit) == tip)
    {
      var changed = await Run(["diff", "--name-only", "-z", "--no-renames", tip, workCommit]);
      if (!changed.Ok) throw new Failure("its unsaved work could not be read (" + Line(changed) + ")");
      var paths = changed.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries);
      var tracked = (await Run(["ls-files", "-z"])).Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
      var onDisk = paths.Where(p => !tracked.Contains(p) && CodeBackupDisk.Exists(Path.Combine(folder, p))).ToList();
      if (onDisk.Count > 0)
      {
        var keep = Path.Combine(await GitDirectory(), "terminal-deck-switch", "kept-" + FileStamp(now));
        foreach (var path in onDisk)
        {
          var destination = Path.Combine(keep, path);
          try
          {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            if (!File.Exists(destination)) File.Copy(Path.Combine(folder, path), destination);
          }
          catch (Exception error) when (error is IOException or UnauthorizedAccessException)
          {
            throw new Failure(path + " (a file Git ignores here) could not be kept first, so the unsaved work was not laid in");
          }
        }
        result.KeptIgnoredFolder = keep; result.KeptIgnored = onDisk.Order(StringComparer.Ordinal).ToList();
      }
      if (stashed) { plan.Laid = workCommit; await record(plan); }
      var laid = await Run(["restore", "--source=" + workCommit, "--worktree", "--overlay", "--", "."], timeout: 600_000);
      if (!laid.Ok) throw new Failure("its unsaved work could not be laid in (" + Line(laid) + ")", laidIn: true);
    }
    return result;
  }

  // ---- never losing his changes after the stash ----

  private async Task<string> GitDirectory()
  {
    var read = await Run(["rev-parse", "--absolute-git-dir"]);
    if (!read.Ok || Text(read).Length == 0) throw new Failure("Git could not read the folder");
    return Path.GetFullPath(Text(read));
  }
  /// A PC with no Git name set still gets its changes put aside and back (Git needs a name to make a stash).
  private async Task<IReadOnlyDictionary<string, string>> Identity()
  {
    if ((await Run(["config", "--get", "user.email"])).Ok) return new Dictionary<string, string>();
    return new Dictionary<string, string> { ["GIT_AUTHOR_NAME"] = "Terminal Deck", ["GIT_AUTHOR_EMAIL"] = "terminal-deck@localhost", ["GIT_COMMITTER_NAME"] = "Terminal Deck", ["GIT_COMMITTER_EMAIL"] = "terminal-deck@localhost" };
  }
  /// `stash@{n}` of the stash with exactly this message (null: there is none).
  private async Task<string?> StashRef(string message)
  {
    var list = await Run(["stash", "list", "--format=%gd%x09%gs"]);
    foreach (var row in list.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      var parts = row.TrimEnd('\r').Split('\t', 2);
      if (parts.Length == 2 && (parts[1] == message || parts[1].EndsWith(": " + message, StringComparison.Ordinal))) return parts[0];
    }
    return null;
  }
  /// Back exactly where he was: his branch at his commit, what the switch laid in taken away (files Git ignores are never
  /// touched), then his stash applied with its staged part. `partly`: nothing is reset or removed, the stash is only applied.
  private async Task<(bool Back, string Line)> PutBack(Pending plan, bool partly = false)
  {
    if (await StashRef(plan.Stash) is not { } reference) return (true, "");
    var ok = true;
    if (!partly)
    {
      ok = (await Run(["checkout", "-q", "-f", plan.Branch ?? plan.Head])).Ok;
      if (ok && plan.Moved is { } moved && moved == plan.Branch && plan.Head.Length > 0) ok = (await Run(["reset", "-q", "--hard", plan.Head])).Ok;
      if (ok) ok = (await Run(["clean", "-q", "-f", "-d"])).Ok;
    }
    if (ok) ok = (await Run(["stash", "pop", "--index", "-q", reference], extra: await Identity())).Ok;
    if (ok && await StashRef(plan.Stash) is null) return (true, "Your unsaved changes here are back as they were.");
    var now_ = await StashRef(plan.Stash) ?? reference;
    return (false, "Your unsaved changes here are kept in Git as \"" + plan.Stash + "\"; to bring them back, in the project folder: git stash apply " + now_);
  }
  private async Task<Failure> FailAfterStash(Failure failure, Pending plan, bool partly = false)
  {
    if (!failure.LaidIn)
    {
      var later = "";
      if (!partly)
      {
        var edits = await SetAsideLaterEdits(plan);
        if (edits.Failed)
        {
          var reference = await StashRef(plan.Stash) ?? "stash@{0}";
          await record(null);
          return new(failure.Plain + ". The files changed here during the switch could not be put aside, so nothing was undone: "
            + "your unsaved changes from before it are kept in Git as \"" + plan.Stash + "\"; to bring them back, in the project folder: git stash apply " + reference,
            plan.Stash, "git stash apply " + reference);
        }
        if (edits.Stashed is { } name) later = " Files changed here during the switch are kept as '" + name + "'.";
        else if (edits.Copied is { } copies) later = " Files changed here during the switch are kept as copies in '" + copies + "'.";
      }
      var back = await PutBack(plan, partly);
      await record(null);
      if (back.Back) return new(failure.Plain + ". " + back.Line + later);
      return new(failure.Plain + ". " + back.Line + later, plan.Stash, Command(back.Line));
    }
    var stashReference = await StashRef(plan.Stash) ?? "stash@{0}";
    await record(null);
    return new(failure.Plain + ". Your unsaved changes here are kept in Git as \"" + plan.Stash + "\"; to bring them back, in the project folder: git stash apply " + stashReference,
      plan.Stash, "git stash apply " + stashReference);
  }
  /// A switch stopped half-way earlier: undone, his changes put back; the sentence for the result.
  private async Task<string?> UndoInterrupted(Pending plan)
  {
    var when = Stamp(DateTimeOffset.FromUnixTimeMilliseconds(plan.At).ToOffset(now.Offset));
    if (await StashRef(plan.Stash) is not { } original) { await record(null); return null; }
    var edits = await SetAsideLaterEdits(plan);
    if (edits.Failed)
      throw new Failure("A switch here was stopped half-way at " + when + " and the files you changed since could not be put aside, so nothing was undone: "
        + "your changes from before it are in Git as \"" + plan.Stash + "\" (git stash apply " + original + "); save your work, then switch again", plan.Stash, "git stash apply " + original);
    var back = await PutBack(plan);
    await record(null);
    var later = edits.Stashed is { } name ? " You changed files here while the switch was stopped; those changes are kept as '" + name + "'."
      : edits.Copied is { } copies ? " You changed files here while the switch was stopped; those changes are kept as copies in '" + copies + "'." : "";
    if (!back.Back) throw new Failure("A switch here was stopped half-way at " + when + ". " + back.Line + later, plan.Stash, Command(back.Line));
    return "A switch here was stopped half-way at " + when + "; it was undone and your unsaved changes were put back first." + later;
  }

  private sealed record LaterEdits(bool Failed = false, string? Stashed = null, string? Copied = null);
  /// Compares the folder with what the stopped switch itself left. Changed tracked files and new untracked files that
  /// differ from that are his: put aside in a stash of their own (untracked included), else copied. Ignored files untouched.
  private async Task<LaterEdits> SetAsideLaterEdits(Pending plan)
  {
    var status = await Run(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"]);
    if (!status.Ok) return new(Failed: true);
    var paths = CodeBackupReader.StatusNames(status.Output);
    if (paths.Count == 0) return new();
    var his = new List<string>();
    foreach (var path in paths)
    {
      if (plan.Laid is { } laid && CodeBackupDisk.Exists(Path.Combine(folder, path)))
      {
        var blob = await Run(["rev-parse", "--verify", "--quiet", laid + ":" + path]);
        var file = await Run(["hash-object", "--no-filters", "--", path]);
        if (blob.Ok && file.Ok && Text(blob) == Text(file)) continue;
      }
      his.Add(path);
    }
    if (his.Count == 0) return new();
    var name = "Terminal Deck: your edits made during a stopped switch, " + Stamp(now);
    await Run(["stash", "push", "--include-untracked", "-m", name], extra: await Identity());
    var after = await Run(["status", "--porcelain=v1", "--untracked-files=all"]);
    if (await StashRef(name) is not null && after.Ok && Text(after).Length == 0) return new(Stashed: name);
    var rest = await Run(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"]);
    var keep = Path.Combine(await GitDirectory(), "terminal-deck-switch", "kept-" + FileStamp(now) + "-edits");
    foreach (var path in CodeBackupReader.StatusNames(rest.Output))
    {
      var source = Path.Combine(folder, path);
      if (!File.Exists(source)) continue;
      try
      {
        var destination = Path.Combine(keep, path);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (!File.Exists(destination)) File.Copy(source, destination);
      }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return new(Failed: true); }
    }
    return await StashRef(name) is not null ? new(Stashed: name + "' and copies in '" + keep) : new(Copied: keep);
  }
  public static string? Command(string line) => line.IndexOf("git stash apply ", StringComparison.Ordinal) is var at and >= 0 ? line[at..] : null;
  public static string FileStamp(DateTimeOffset date) => date.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
  public static string Stamp(DateTimeOffset date) => date.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
}

// The two computers' code steps on the Code page's one actions object (so a move never runs beside another backup).
public sealed partial class CodeBackupActions
{
  /// The old computer, after the session stopped: Back up now (not marked as his own click), then the exact names the
  /// hand-over carries: his branch, the backed-up commit for it, and the copy of his uncommitted work when he has any.
  public async Task<CodeBackupHandOver?> HandOver(string? projectId, string folder)
  {
    if (projectId is null || (await Projects.List()).FirstOrDefault(p => p.Id == projectId) is not { } project) return null;
    var outcome = await BackUp(projectId);
    var (_, places) = await Projects.Fresh(project);
    if (places.Count == 0) return new(outcome.Ok, null, null, null, null);
    var place = places[0];
    async Task<string?> Read(IReadOnlyList<string> arguments, bool shadow = false)
    {
      var environment = shadow ? new Dictionary<string, string> { ["GIT_DIR"] = Shadow(workArea, place.GitDir) } : new Dictionary<string, string>();
      var result = await git.RunAsync(place.Top, arguments, environment, 30_000, 1_048_576);
      var text = result.Ok ? result.Output.Trim() : "";
      return text.Length == 0 ? null : text;
    }
    var branch = await Read(["symbolic-ref", "--quiet", "--short", "HEAD"]);
    var tip = await Read(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]);
    var at = Ledger.Coverage(place.GitDir)?.At ?? 0;
    var handOver = new CodeBackupHandOver(outcome.Ok, at > 0 ? at : null, branch, tip, null);
    if (!outcome.Ok || Ledger.Home(projectId) is not { } home || await account.Transport(home) is not { } transport) return handOver;
    var area = CodeBackupPlan.Mine(computer); var part = CodeBackupPlan.Part(branch ?? "no-branch");
    var listing = await git.RunAsync(place.Top, ["ls-remote", "--", transport.Url, area + "heads/" + part, area + "work/" + part], transport.Environment, 120_000, 1_048_576);
    if (!listing.Ok) return handOver;
    var found = listing.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(r => r.TrimEnd('\r').Split('\t', 2)).Where(p => p.Length == 2).ToDictionary(p => p[1], p => p[0]);
    // A keeper counts only when it keeps exactly the commit he is on.
    if (found.TryGetValue(area + "heads/" + part, out var keeper) && tip is not null && await Read(["rev-parse", "--verify", "--quiet", keeper + "^1"], shadow: true) == tip)
      handOver = handOver with { HeadSha = keeper };
    // The work copy only when there IS uncommitted work now.
    if (found.TryGetValue(area + "work/" + part, out var workCopy) && await Read(["status", "--porcelain=v1", "--untracked-files=all"]) is not null
        && await Read(["rev-parse", "--verify", "--quiet", workCopy + "^1"], shadow: true) == tip)
      handOver = handOver with { WorkSha = workCopy };
    return handOver;
  }

  /// This PC: the old computer's code into the project's folder. GitHub not connected: nothing changes here.
  public async Task<CodeBackupTakeCode.Result> TakeCode(string? projectId, string folder, CodeBackupTakeCode.Named named, CodeBackupTakeCode.Pending? pending = null,
    Func<CodeBackupTakeCode.Pending?, Task>? record = null, Action<string>? progress = null)
  {
    if (await account.Login() is not { } login) return new(CodeBackupTakeCode.Kind.NotConnected);
    var home = projectId is null ? null : Ledger.Home(projectId);
    var project = projectId is null ? null : (await Projects.List()).FirstOrDefault(p => p.Id == projectId);
    if (home is null && project is not null) home = (await Projects.Fresh(project)).Row.Home;
    if (home is null && project is not null) home = Match(project.Name, await account.Repositories(), login);
    if (home is null) return new(CodeBackupTakeCode.Kind.NothingBackedUp);
    if (await account.Transport(home) is not { } transport) return new(CodeBackupTakeCode.Kind.NotConnected);
    var result = await new CodeBackupTakeCode(git, transport, "https://" + host + "/" + home + ".git", folder, home, host, now(), pending, record, progress).Perform(named);
    if (projectId is not null)
    {
      if (result.Kind is not (CodeBackupTakeCode.Kind.Failed or CodeBackupTakeCode.Kind.OtherProject)) Ledger.SetHome(projectId, home);
      Projects.Forget(projectId);
    }
    return result;
  }

  /// When this PC last backed the project up.
  public long? LastBackup(string projectId) => Ledger.SentAt(projectId);
}
