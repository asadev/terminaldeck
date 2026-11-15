using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Code;

/// Where Git sends and fetches for a GitHub home, and the process settings that carry the sign-in. The token is only ever
/// in the child's environment (GIT_CONFIG_*), never in an argument, a URL, a file or a log line.
public sealed record CodeBackupTransport(string Url, IReadOnlyDictionary<string, string> Environment, IReadOnlyList<string>? Secrets = null)
{
  private static readonly Regex Tokens = new(@"(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|x-access-token:[^@\s]+|Authorization:\s*\S+\s+\S+)", RegexOptions.Compiled);
  public string Scrub(string text)
  {
    foreach (var secret in Secrets ?? []) if (Encoding.UTF8.GetByteCount(secret) >= 8) text = text.Replace(secret, "[hidden]", StringComparison.Ordinal);
    return Tokens.Replace(text, "[hidden]");
  }

  /// HTTPS only, the sign-in as a header for that host only, no stored helpers, no prompts, no redirects.
  public static CodeBackupTransport Https(string host, string home, string token)
  {
    var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes("x-access-token:" + token));
    (string, string)[] settings =
    [
      ("credential.helper", ""), ("core.askPass", ""), ("http.followRedirects", "false"),
      ("http.https://" + host + "/.extraHeader", "Authorization: Basic " + encoded),
      ("protocol.allow", "never"), ("protocol.https.allow", "always"),
    ];
    return new("https://" + host + "/" + home + ".git", CodeBackupGitRunner.Settings(settings, new Dictionary<string, string>
    {
      ["GIT_TERMINAL_PROMPT"] = "0", ["GCM_INTERACTIVE"] = "never", ["GIT_ASKPASS"] = "", ["SSH_ASKPASS"] = ""
    }), [token, encoded]);
  }
}

/// The "adds only" rule, in one place and tested on its own. What may be sent to GitHub is a list of
/// `<commit>:<full reference>` pairs: never a `+` (a forced update), never an empty source (a deletion), never a pattern.
/// Git itself then refuses anything that is not a fast-forward and any existing tag.
///
/// Correction 14 Nov (lead): on a home he already had the backup writes ONLY under `refs/terminal-deck-backup/<PC>/…`,
/// which is neither a branch nor a tag. Review 14 Nov: in this release every home gets only those references.
public static class CodeBackupPlan
{
  public sealed record Step(string Commit, string Reference) { public string Refspec => Commit + ":" + Reference; }
  public const string Namespace = "refs/terminal-deck-backup/";
  public static readonly bool RealNamesAllowed = false;
  /// Slice-2 first draft used branches with this prefix; never sent any more, still skipped when seen.
  public const string Prefix = "terminal-deck-backup/";

  public static string Mine(string computer) => Namespace + Part(computer) + "/";

  public static bool AddsOnly(string refspec)
  {
    if (refspec.StartsWith('+') || refspec.StartsWith(':') || refspec.StartsWith('^') || refspec.Contains('*')) return false;
    var colon = refspec.IndexOf(':');
    if (colon < 0 || refspec.IndexOf(':', colon + 1) >= 0) return false;
    var source = refspec[..colon]; var destination = refspec[(colon + 1)..];
    if (source.Length < 40 || !source.All(Uri.IsHexDigit)) return false;
    if (!(destination.StartsWith("refs/heads/", StringComparison.Ordinal) || destination.StartsWith("refs/tags/", StringComparison.Ordinal) || destination.StartsWith(Namespace, StringComparison.Ordinal))) return false;
    return !destination.Contains("..") && !destination.Contains("@{") && !destination.Contains("//") && !destination.EndsWith('/')
      && !destination.EndsWith(".lock", StringComparison.Ordinal) && !destination.Any(c => c < 0x21 || c == 0x7f)
      && !destination.Any(c => c is '~' or '^' or '?' or '[' or '\\' or ':');
  }

  /// Every step stays in the private references: nothing under refs/heads/ or refs/tags/.
  public static bool PrivateOnly(IEnumerable<Step> steps) => steps.All(s => s.Reference.StartsWith(Namespace, StringComparison.Ordinal) && AddsOnly(s.Refspec));

  /// A home Terminal Deck made: his branches and tags under their real names, fast-forward only, an existing tag never
  /// moved (unreachable while RealNamesAllowed is false; kept as the Mac keeps it).
  public static (List<Step> Send, List<string> Skipped) Make(IReadOnlyDictionary<string, string> branches, IReadOnlyDictionary<string, string> tags,
    IReadOnlyDictionary<string, string> remote, Func<string, string, bool?> contains)
  {
    var send = new List<Step>(); var skipped = new List<string>();
    foreach (var (name, commit) in branches.OrderBy(b => b.Key, StringComparer.Ordinal).Where(b => !b.Key.StartsWith(Prefix, StringComparison.Ordinal)))
    {
      var reference = "refs/heads/" + name;
      if (remote.TryGetValue(reference, out var theirs))
      {
        if (theirs == commit) continue;
        if (contains(theirs, commit) == true) send.Add(new(commit, reference)); else skipped.Add(name + ": GitHub has other work on this branch");
      }
      else send.Add(new(commit, reference));
    }
    foreach (var (name, commit) in tags.OrderBy(t => t.Key, StringComparer.Ordinal).Where(t => !remote.ContainsKey("refs/tags/" + t.Key))) send.Add(new(commit, "refs/tags/" + name));
    return (send.Where(s => AddsOnly(s.Refspec)).ToList(), skipped);
  }

  /// `push --porcelain`: the references GitHub took ("*" new, " " moved forward, "=" already there).
  public static HashSet<string> Accepted(string porcelain)
  {
    var taken = new HashSet<string>(StringComparer.Ordinal);
    foreach (var line in porcelain.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      var parts = line.TrimEnd('\r').Split('\t');
      if (parts.Length < 2 || parts[0].Length == 0 || parts[0][0] is not ('*' or ' ' or '=')) continue;
      var colon = parts[1].LastIndexOf(':');
      if (colon >= 0) taken.Add(parts[1][(colon + 1)..]);
    }
    return taken;
  }

  /// A branch or computer name as one part of a reference: letters, digits, '.', '_' and '-' only ("/" becomes "--").
  public static string Part(string name)
  {
    var out_ = new StringBuilder();
    foreach (var c in name.Replace("/", "--")) out_.Append(char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' ? c : '-');
    var text = out_.ToString();
    while (text.Contains("..")) text = text.Replace("..", ".-");
    while (text.StartsWith('.') || text.StartsWith('-')) text = text[1..];
    if (text.EndsWith(".lock", StringComparison.Ordinal) || text.EndsWith('.')) text += "-";
    return text.Length == 0 ? "x" : text[..Math.Min(80, text.Length)];
  }
}

/// Backs up ONE repository whose top folder the caller has already proved is the project's code, to a PRIVATE home. What
/// it changes, all of it additions: on GitHub only references under `refs/terminal-deck-backup/<PC>/` (each branch as a
/// "keeper" commit whose FIRST parent is his branch exactly as it is and whose second parent is the previous keeper, so
/// the reference only ever moves forward); in his repository NOTHING. Fetched objects, the copies and every reference this
/// needs live in the app's own repository for the project (`shadow`), which reads his objects through `alternates`.
public sealed class CodeBackupSend(ICodeBackupGit git, string top, string gitDir, string remoteName, CodeBackupTransport transport, bool realNames,
  string computer, CodeBackupLedger ledger, DateTimeOffset now, string shadow)
{
  public sealed class Result
  {
    public int Sent { get; set; }
    public List<string> Skipped { get; } = [];
    public List<CodeBackupCoverage.LeftOutFile> LeftOut { get; set; } = [];
    public string? Failure { get; set; }
    public bool BecameLoud { get; set; }
  }
  private sealed class Failure(string plain) : Exception(plain) { public string Plain { get; } = plain; }
  public const string HomeRemote = "home";
  public const string Unchecked = "a file that could not be checked";
  public string RemoteName { get; } = remoteName;

  private async Task<CodeProcessResult> Run(IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string>? environment = null, bool network = false, bool his = false,
    int timeout = 60_000, int maximum = 16 * 1024 * 1024)
  {
    var extra = new Dictionary<string, string>(environment ?? new Dictionary<string, string>());
    if (!his)
    {
      extra["GIT_DIR"] = shadow;
      if (extra.ContainsKey("GIT_INDEX_FILE")) extra["GIT_WORK_TREE"] = top;
    }
    var outcome = await git.RunAsync(top, arguments, network ? CodeBackupGitRunner.Merge(transport.Environment, extra) : extra, timeout, maximum);
    if (outcome.Missing) throw new Failure("Git is not installed on this PC");
    return outcome;
  }
  private string Line(CodeProcessResult outcome)
  {
    var text = transport.Scrub(outcome.Error).Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0) ?? "";
    return text[..Math.Min(160, text.Length)];
  }
  private static string Trimmed(CodeProcessResult outcome) => outcome.Output.Trim();

  public static string? GitBusy(string gitDir)
  {
    (string Name, string What)[] markers = [("MERGE_HEAD", "a merge"), ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"), ("CHERRY_PICK_HEAD", "a cherry-pick"),
      ("REVERT_HEAD", "a revert"), ("BISECT_LOG", "a bisect"), ("sequencer", "a cherry-pick"), ("index.lock", "a Git command")];
    foreach (var (name, what) in markers) if (CodeBackupDisk.Exists(Path.Combine(gitDir, name))) return what;
    return null;
  }

  public async Task<Result> Perform()
  {
    var result = new Result();
    try { await Body(result); }
    catch (Failure failure) { result.Failure = failure.Plain; }
    catch (OperationCanceledException) { result.Failure = "stopped"; }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { result.Failure = "Git could not be started"; }
    return result;
  }

  private static Dictionary<string, string> Pairs(string text)
  {
    var pairs = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var row in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      var parts = row.TrimEnd('\r').Split('\t', 2);
      if (parts.Length == 2) pairs[parts[0]] = parts[1];
    }
    return pairs;
  }

  private async Task Body(Result result)
  {
    if (GitBusy(gitDir) is { } busy) throw new Failure("Git is in the middle of " + busy + " here; tried again later");
    var mine = CodeBackupPlan.Mine(computer);
    await PrepareShadow();
    // 1. What the home has now, read from GitHub itself.
    var listing = await Run(["ls-remote", "--", transport.Url], network: true, timeout: 120_000);
    if (!listing.Ok) throw new Failure("GitHub did not answer (" + Line(listing) + ")");
    var remote = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var row in listing.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      var parts = row.TrimEnd('\r').Split('\t', 2);
      if (parts.Length == 2 && !parts[1].EndsWith("^{}", StringComparison.Ordinal)) remote[parts[1]] = parts[0];
    }
    // 2. Its commits, so "moves forward" can be checked here. Only the app's own references change.
    if (remote.Count > 0)
    {
      var refspecs = new List<string> { "+refs/heads/*:refs/remotes/" + HomeRemote + "/*", "^refs/heads/" + CodeBackupPlan.Prefix + "*" };
      refspecs.AddRange(remote.Keys.Where(k => k.StartsWith(mine, StringComparison.Ordinal)).Order(StringComparer.Ordinal));
      var fetched = await Run(["fetch", "--quiet", "--prune", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--", transport.Url, .. refspecs], network: true, timeout: 600_000);
      if (!fetched.Ok) throw new Failure("GitHub's copy could not be read (" + Line(fetched) + ")");
    }
    // 3. A made home that now carries a workflow file is a home things hang on: private references from now on.
    var useRealNames = realNames && CodeBackupPlan.RealNamesAllowed;
    if (useRealNames && await CarriesWorkflow(remote)) { useRealNames = false; result.BecameLoud = true; }

    // 4. His branches and tags.
    var branches = Pairs((await Run(["for-each-ref", "--format=%(refname:strip=2)%09%(objectname)", "refs/heads"], his: true)).Output);
    var tags = Pairs((await Run(["for-each-ref", "--format=%(refname:strip=2)%09%(objectname)", "refs/tags"], his: true)).Output);
    var currentRead = await Run(["symbolic-ref", "--quiet", "--short", "HEAD"], his: true);
    var current = currentRead.Ok ? Trimmed(currentRead) : null;
    var before = ledger.Coverage(gitDir);
    var heads = new Dictionary<string, string>(before?.Heads ?? [], StringComparer.Ordinal);
    var steps = new List<CodeBackupPlan.Step>();
    var keeperFor = new Dictionary<string, (string Branch, string Tip)>(StringComparer.Ordinal);
    var identity = await Author();
    var when = CodeBackupWords.When(now.ToUnixTimeMilliseconds(), now);

    if (useRealNames)
    {
      var ancestry = new Dictionary<string, bool?>();
      foreach (var (name, commit) in branches)
      {
        if (!remote.TryGetValue("refs/heads/" + name, out var theirs) || theirs == commit) continue;
        var check = await Run(["merge-base", "--is-ancestor", theirs, commit]);
        ancestry[theirs + ":" + commit] = check.ExitCode == 0 ? true : check.ExitCode == 1 ? false : null;
      }
      var plan = CodeBackupPlan.Make(branches, tags, remote, (a, b) => ancestry.GetValueOrDefault(a + ":" + b));
      result.Skipped.AddRange(plan.Skipped);
      foreach (var step in plan.Send)
      {
        if (await SecretIn(step.Commit, []) is { } secret)
        {
          var what = step.Reference.StartsWith("refs/tags/", StringComparison.Ordinal) ? "tag " + step.Reference["refs/tags/".Length..] : step.Reference["refs/heads/".Length..];
          result.Skipped.Add(what + ": not sent: " + secret + " is in its commits"); continue;
        }
        steps.Add(step);
      }
    }
    else
    {
      foreach (var (name, tip) in branches.OrderBy(b => b.Key, StringComparer.Ordinal).Where(b => !b.Key.StartsWith(CodeBackupPlan.Prefix, StringComparison.Ordinal)))
      {
        var reference = mine + "heads/" + name;
        remote.TryGetValue(reference, out var previous);
        if (heads.GetValueOrDefault(name) == tip && previous is not null) continue;
        if (remote.TryGetValue("refs/heads/" + name, out var theirs) && (await Run(["merge-base", "--is-ancestor", tip, theirs])).ExitCode == 0) { heads[name] = tip; continue; }
        if (previous is not null && Trimmed(await Run(["rev-parse", "--verify", "--quiet", previous + "^1"])) == tip) { heads[name] = tip; continue; }
        if (await SecretIn(tip, heads.Values.ToList()) is { } secret) { result.Skipped.Add(name + ": not sent: " + secret + " is in its commits"); continue; }
        var tree = await Run(["rev-parse", tip + "^{tree}"]);
        if (!tree.Ok) { result.Skipped.Add(name + ": could not be read"); continue; }
        var parents = new List<string> { tip };
        if (previous is not null && (await Run(["cat-file", "-e", previous + "^{commit}"])).Ok) parents.Add(previous);
        var keeper = await Run(["commit-tree", Trimmed(tree), "--no-gpg-sign", .. parents.SelectMany(p => new[] { "-p", p }), "-m", "Branch " + name + " on " + computer + ", " + when + " (Terminal Deck backup)"], identity);
        if (!keeper.Ok) { result.Skipped.Add(name + ": could not be copied"); continue; }
        steps.Add(new(Trimmed(keeper), reference)); keeperFor[reference] = (name, tip);
      }
      foreach (var (name, commit) in tags.OrderBy(t => t.Key, StringComparer.Ordinal))
      {
        var reference = mine + "tags/" + name;
        if (remote.GetValueOrDefault("refs/tags/" + name) == commit) continue;
        if (remote.TryGetValue(reference, out var theirs)) { if (theirs != commit) result.Skipped.Add("tag " + name + ": kept earlier with other content"); continue; }
        if (await SecretIn(commit, [.. heads.Values, .. keeperFor.Values.Select(k => k.Tip)]) is { } secret) { result.Skipped.Add("tag " + name + ": not sent: " + secret + " is in its commits"); continue; }
        steps.Add(new(commit, reference));
      }
    }
    // 5. Uncommitted work and set-aside changes: always under the private references.
    var safe = heads.Values.Concat(keeperFor.Values.Select(k => k.Tip)).Concat(steps.Where(s => s.Reference.StartsWith("refs/heads/", StringComparison.Ordinal)).Select(s => s.Commit)).ToList();
    var (snapshotSteps, coverage, leftOut, held) = await Snapshots(remote, mine + "work/" + CodeBackupPlan.Part(current ?? "no-branch"), mine + "set-aside", identity, when, safe);
    steps.AddRange(snapshotSteps); result.LeftOut = leftOut; result.Skipped.AddRange(held);

    // 6. Send. Every step passed AddsOnly; on a home he already had, every step is a private reference.
    var checkedSteps = steps.Where(s => CodeBackupPlan.AddsOnly(s.Refspec)).ToList();
    if (!useRealNames && !CodeBackupPlan.PrivateOnly(checkedSteps)) throw new Failure("a backup step would have touched a branch or tag; nothing was sent");
    var taken = new HashSet<string>(StringComparer.Ordinal);
    if (checkedSteps.Count > 0)
    {
      taken = await Push(checkedSteps);
      if (taken.Count < checkedSteps.Count)
        foreach (var step in checkedSteps.Where(s => !taken.Contains(s.Reference)).ToList())
        {
          var single = await Push([step]);
          taken.UnionWith(single);
          if (single.Count == 0)
          {
            var what = step.Reference.StartsWith(CodeBackupPlan.Namespace, StringComparison.Ordinal) ? step.Reference[mine.Length..] : step.Reference.Split('/', 3)[^1];
            result.Skipped.Add(what + ": GitHub did not take it");
          }
        }
    }
    result.Sent = taken.Count;
    if (checkedSteps.Count > 0 && taken.Count == 0 && checkedSteps.All(s => s.Reference.StartsWith(CodeBackupPlan.Namespace, StringComparison.Ordinal)))
      throw new Failure("GitHub did not accept the private backup references; nothing was sent to your branches");
    // 7. The app's own record of GitHub's branches follows real branches that moved (made homes only).
    foreach (var step in checkedSteps.Where(s => taken.Contains(s.Reference) && s.Reference.StartsWith("refs/heads/", StringComparison.Ordinal)))
      await Run(["update-ref", "-m", "Terminal Deck backup", "refs/remotes/" + HomeRemote + "/" + step.Reference["refs/heads/".Length..], step.Commit]);
    foreach (var (reference, keptBranch) in keeperFor) if (taken.Contains(reference)) heads[keptBranch.Branch] = keptBranch.Tip;
    // 8. What is safe now.
    var record = coverage;
    if (!snapshotSteps.All(s => taken.Contains(s.Reference)))
    {
      result.Failure = "GitHub did not take the copy of your uncommitted work";
      record.Fingerprint = before?.Fingerprint ?? ""; record.Stashes = before?.Stashes ?? []; record.LeftOut = before?.LeftOut ?? []; record.At = before?.At ?? 0;
    }
    else record.At = now.ToUnixTimeMilliseconds();
    record.Heads = heads.Where(h => branches.ContainsKey(h.Key)).ToDictionary(h => h.Key, h => h.Value, StringComparer.Ordinal);
    ledger.SetCoverage(gitDir, record);
  }

  /// The app's own repository for this project: made once (bare), its object store borrowing his (`alternates`). Only the
  /// app's data folder is written.
  private async Task PrepareShadow()
  {
    var common = await Run(["rev-parse", "--path-format=absolute", "--git-common-dir"], his: true);
    var objects = Trimmed(common) + "/objects";
    if (!common.Ok || !Directory.Exists(objects)) throw new Failure("Git could not read the folder");
    if (!File.Exists(Path.Combine(shadow, "HEAD")))
    {
      Directory.CreateDirectory(shadow);
      var made = await git.RunAsync(shadow, ["init", "--bare", "-q", "."], new Dictionary<string, string>(), 30_000, 65_536);
      if (made.Missing) throw new Failure("Git is not installed on this PC");
      if (!made.Ok) throw new Failure("Terminal Deck could not prepare its backup area");
    }
    var alternates = Path.Combine(shadow, "objects", "info", "alternates");
    string? existing = null;
    try { existing = File.Exists(alternates) ? File.ReadAllText(alternates) : null; } catch (IOException) { }
    if (existing != objects + "\n")
    {
      Directory.CreateDirectory(Path.Combine(shadow, "objects", "info"));
      File.WriteAllBytes(alternates + ".tmp", Encoding.UTF8.GetBytes(objects + "\n"));
      File.Move(alternates + ".tmp", alternates, overwrite: true);
    }
  }

  private async Task<bool> CarriesWorkflow(IReadOnlyDictionary<string, string> remote)
  {
    foreach (var (reference, commit) in remote)
    {
      if (!reference.StartsWith("refs/heads/", StringComparison.Ordinal) || reference.StartsWith("refs/heads/" + CodeBackupPlan.Prefix, StringComparison.Ordinal)) continue;
      var listed = await Run(["ls-tree", "--name-only", commit, ".github/workflows/"]);
      if (listed.Ok && Trimmed(listed).Length > 0) return true;
    }
    return false;
  }

  /// The first file added or changed by the commits of `tip` that GitHub does not have yet that holds a commit back.
  private async Task<string?> SecretIn(string tip, IReadOnlyList<string> beyond)
  {
    var listed = await Run(["log", "--format=", "--raw", "-z", "-m", "--no-abbrev", "--no-renames", "--diff-filter=AM", tip, "--not", "--remotes=" + HomeRemote, .. beyond], maximum: 32 * 1024 * 1024);
    if (!listed.Ok || listed.TimedOut) return Unchecked;
    return await FirstHeld(RawEntries(listed.Output));
  }

  /// `--raw -z` output (log, diff-tree): ":<mode> <mode> <old> <new> <status>\0<path>\0" per file.
  public static List<(string Blob, string Path)> RawEntries(string text)
  {
    var entries = new List<(string, string)>(); string? pending = null;
    foreach (var token in text.Split('\0'))
    {
      if (pending is not null) { entries.Add((pending, token)); pending = null; continue; }
      var meta = token.Trim();
      if (!meta.StartsWith(':')) continue;
      var fields = meta.Split(' ', StringSplitOptions.RemoveEmptyEntries);
      if (fields.Length >= 5) pending = fields[3];
    }
    return entries;
  }

  private async Task<string?> FirstHeld(IEnumerable<(string Blob, string Path)> entries)
  {
    foreach (var (blob, path) in entries)
    {
      var name = path.Split('/')[^1];
      switch (CodeBackupReader.KindOf(path))
      {
        case CodeBackupReader.SecretKind.Credential: return name;
        case CodeBackupReader.SecretKind.MaybeKey: if (await BlobHoldsPrivateKey(blob)) return name; break;
      }
    }
    return null;
  }

  private async Task<bool> BlobHoldsPrivateKey(string blob)
  {
    var size = await Run(["cat-file", "-s", blob]);
    if (!size.Ok || !int.TryParse(Trimmed(size), out var bytes)) return true;
    if (bytes > CodeBackupReader.KeyBytes) return false;
    var body = await Run(["cat-file", "blob", blob], maximum: CodeBackupReader.KeyBytes + 65_536);
    if (!body.Ok || body.TimedOut) return true;
    return body.Output.Contains("PRIVATE KEY", StringComparison.Ordinal);
  }

  private async Task<HashSet<string>> Push(IReadOnlyList<CodeBackupPlan.Step> steps)
  {
    var outcome = await Run(["push", "--porcelain", "--no-verify", "--no-follow-tags", "--recurse-submodules=no", "--no-signed", transport.Url, .. steps.Select(s => s.Refspec)], network: true, timeout: 600_000);
    return CodeBackupPlan.Accepted(outcome.Output);
  }

  /// A set-aside change carrying a secret file (in its change, its staged part, its untracked part, or in the commits under
  /// it) stays on this PC.
  private async Task<string?> StashSecret(string stash, IReadOnlyList<string> safe)
  {
    if (await SecretIn(stash + "^1", safe) is { } secret) return secret;
    var entries = new List<(string, string)>();
    foreach (var (from, to) in new[] { (stash + "^1", stash), (stash + "^1", stash + "^2") })
    {
      var changed = await Run(["diff-tree", "-r", "-z", "--no-abbrev", "--no-renames", "--no-commit-id", "--diff-filter=AM", from, to]);
      if (!changed.Ok || changed.TimedOut) return Unchecked;
      entries.AddRange(RawEntries(changed.Output));
    }
    if ((await Run(["rev-parse", "--verify", "--quiet", stash + "^3^{commit}"])).Ok)
    {
      var untracked = await Run(["ls-tree", "-r", "-z", stash + "^3"]);
      if (!untracked.Ok || untracked.TimedOut) return Unchecked;
      foreach (var row in untracked.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries))
      {
        var tab = row.IndexOf('\t');
        if (tab < 0) continue;
        var fields = row[..tab].Split(' ');
        if (fields.Length == 3) entries.Add((fields[2], row[(tab + 1)..]));
      }
    }
    return await FirstHeld(entries);
  }

  /// Secret files a `.git/info/exclude` the app wrote keeps out of Git's view: still counted as left out.
  private async Task<List<CodeBackupCoverage.LeftOutFile>> ExcludedSecrets()
  {
    var file = Path.Combine(gitDir, "info", "exclude");
    string text;
    try { text = File.Exists(file) ? File.ReadAllText(file) : ""; } catch (IOException) { return []; }
    if (!text.StartsWith(CodeBackupReader.ExcludeMarker, StringComparison.Ordinal)) return [];
    var listed = await Run(["ls-files", "-z", "--others", "--ignored", "--directory", "--exclude-from=" + file], his: true, maximum: 4 * 1024 * 1024);
    if (!listed.Ok) return [];
    return listed.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).Where(n => CodeBackupReader.IsSecret(n.TrimEnd('/'), top)).Select(n => new CodeBackupCoverage.LeftOutFile(n, "secret file")).ToList();
  }

  private async Task<(List<CodeBackupPlan.Step>, CodeBackupCoverage, List<CodeBackupCoverage.LeftOutFile>, List<string>)> Snapshots(IReadOnlyDictionary<string, string> remote,
    string workReference, string setAsideReference, IReadOnlyDictionary<string, string> identity, string when, IReadOnlyList<string> safe)
  {
    var status = await Run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--no-renames"], his: true, maximum: 32 * 1024 * 1024);
    if (!status.Ok || status.TimedOut) throw new Failure("Git could not read the folder");
    var headRead = await Run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], his: true);
    var head = headRead.Ok ? Trimmed(headRead) : null;
    var stashRead = await Run(["log", "--walk-reflogs", "--format=%H", "refs/stash"], his: true);
    var stashes = new List<string>();
    if (stashRead.Ok) foreach (var sha in stashRead.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim())) if (!stashes.Contains(sha)) stashes.Add(sha);
    var fingerprint = CodeBackupCoverage.MakeFingerprint(head ?? "", status.Output, top);
    var names = CodeBackupReader.StatusNames(status.Output);
    var leftOut = new List<CodeBackupCoverage.LeftOutFile>(); var include = new List<string>();
    foreach (var name in names)
    {
      if (CodeBackupReader.IsSecret(name, top)) { leftOut.Add(new(name, "secret file")); continue; }
      if (CodeBackupDisk.RegularSize(Path.Combine(top, name)) is { } size && size > CodeBackupReader.LargeBytes) { leftOut.Add(new(name, "over 50 MB")); continue; }
      include.Add(name);
    }
    var heldBack = new List<string>();
    var before = ledger.Coverage(gitDir);
    var covered = new CodeBackupCoverage { Fingerprint = fingerprint, Stashes = stashes, At = before?.At ?? 0, LeftOut = names.Count == 0 ? [] : [.. leftOut], Heads = before?.Heads };
    var steps = new List<CodeBackupPlan.Step>();
    var scratch = Path.Combine(Path.GetTempPath(), "terminaldeck-code-backup-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(scratch);
    try
    {
      var index = new Dictionary<string, string> { ["GIT_INDEX_FILE"] = Path.Combine(scratch, "index"), ["GIT_LITERAL_PATHSPECS"] = "1" };
      string? underSecret = null;
      if (head is not null && names.Count > 0) underSecret = await SecretIn(head, safe);
      if (underSecret is not null) { heldBack.Add("uncommitted work: not sent: " + underSecret + " is in the commits under it"); covered.Fingerprint = before?.Fingerprint ?? ""; }
      if (underSecret is null && names.Count > 0 && (before?.Fingerprint != fingerprint || !remote.ContainsKey(workReference)))
      {
        var start = await Run(head is not null ? new[] { "read-tree", head } : new[] { "read-tree", "--empty" }, index);
        if (!start.Ok) throw new Failure("Git could not copy your uncommitted work");
        if (include.Count > 0)
        {
          var list = Path.Combine(scratch, "paths");
          File.WriteAllBytes(list, Encoding.UTF8.GetBytes(string.Join('\0', include)));
          var added = await Run(["add", "-A", "--ignore-errors", "--pathspec-from-file=" + list, "--pathspec-file-nul"], index, timeout: 300_000);
          if (!(added.Ok || added.ExitCode == 1)) throw new Failure("Git could not copy your uncommitted work");
        }
        var listed = await Run(["ls-files", "-z"], index, maximum: 32 * 1024 * 1024);
        var secrets = listed.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).Where(n => CodeBackupReader.HoldsBack(n, top)).ToList();
        if (secrets.Count > 0)
        {
          var list = Path.Combine(scratch, "secrets");
          File.WriteAllBytes(list, Encoding.UTF8.GetBytes(string.Join('\0', secrets)));
          var removed = await Run(["rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=" + list, "--pathspec-file-nul"], index);
          if (!removed.Ok) throw new Failure("Git could not leave a secret file out");
        }
        var tree = await Run(["write-tree"], index);
        if (!tree.Ok) throw new Failure("Git could not copy your uncommitted work");
        var parents = new List<string>();
        if (head is not null) parents.Add(head);
        if (remote.TryGetValue(workReference, out var previous) && (await Run(["cat-file", "-e", previous + "^{commit}"])).Ok) parents.Add(previous);
        var made = await Run(["commit-tree", Trimmed(tree), "--no-gpg-sign", .. parents.SelectMany(p => new[] { "-p", p }), "-m", "Uncommitted work on " + computer + ", " + when + " (Terminal Deck backup)"], identity);
        if (!made.Ok) throw new Failure("Git could not copy your uncommitted work");
        steps.Add(new(Trimmed(made), workReference));
      }

      // Set-aside changes: every stash entry as a parent of one commit, so all of them travel and none is changed.
      remote.TryGetValue(setAsideReference, out var previousSetAside);
      var missing = new List<string>(); var clean = new List<string>();
      for (var position = 0; position < stashes.Count; position++)
      {
        var stash = stashes[position];
        if (previousSetAside is not null && (await Run(["merge-base", "--is-ancestor", stash, previousSetAside])).ExitCode == 0) { clean.Add(stash); continue; }
        if (await StashSecret(stash, safe) is { } secret) { heldBack.Add("set-aside change " + (position + 1) + ": not sent: " + secret + " is in it"); continue; }
        clean.Add(stash);
        if (!(before?.Stashes.Contains(stash) ?? false) || previousSetAside is null) missing.Add(stash);
      }
      covered.Stashes = clean;
      if (missing.Count > 0)
      {
        var empty = new Dictionary<string, string> { ["GIT_INDEX_FILE"] = Path.Combine(scratch, "empty-index") };
        await Run(["read-tree", "--empty"], empty);
        var tree = await Run(["write-tree"], empty);
        if (!tree.Ok) throw new Failure("Git could not copy your set-aside changes");
        var parents = new List<string>();
        if (previousSetAside is not null && (await Run(["cat-file", "-e", previousSetAside + "^{commit}"])).Ok) parents.Add(previousSetAside);
        parents.AddRange(clean.Where(c => !parents.Contains(c)).Take(60));
        var made = await Run(["commit-tree", Trimmed(tree), "--no-gpg-sign", .. parents.SelectMany(p => new[] { "-p", p }), "-m", "Set-aside changes on " + computer + ", " + when + " (Terminal Deck backup)"], identity);
        if (!made.Ok) throw new Failure("Git could not copy your set-aside changes");
        steps.Add(new(Trimmed(made), setAsideReference));
      }
      covered.LeftOut = names.Count == 0 ? [] : [.. leftOut];
      var excluded = await ExcludedSecrets();
      return (steps, covered, [.. leftOut, .. excluded], heldBack);
    }
    finally { CodeBackupDisk.Delete(scratch); }
  }

  /// His own name and e-mail from his Git settings; a plain stand-in only when he has none.
  private async Task<IReadOnlyDictionary<string, string>> Author()
  {
    var email = await Run(["config", "--get", "user.email"], his: true);
    var name = await Run(["config", "--get", "user.name"], his: true);
    var mail = email.Ok && Trimmed(email).Length > 0 ? Trimmed(email) : "backup@terminaldeck.invalid";
    var who = name.Ok && Trimmed(name).Length > 0 ? Trimmed(name) : "Terminal Deck";
    return new Dictionary<string, string> { ["GIT_AUTHOR_EMAIL"] = mail, ["GIT_COMMITTER_EMAIL"] = mail, ["GIT_AUTHOR_NAME"] = who, ["GIT_COMMITTER_NAME"] = who };
  }

  internal static string Stamp(DateTimeOffset at) => at.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
}
