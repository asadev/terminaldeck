using System.Text;

namespace TerminalDeck.Core.Code;

/// One project as the Code page reads it: its id, name and code folders (the Projects store's own rows).
public sealed record CodeBackupProjectRef(string Id, string Name, IReadOnlyList<string> Folders)
{
  public bool Same(CodeBackupProjectRef other) => Id == other.Id && Name == other.Name && Folders.SequenceEqual(other.Folders);
}

// Reads a project's code folders with Git, READ-ONLY (port of the Mac's BackendCodeBackupGitReader). Every command runs
// with GIT_OPTIONAL_LOCKS=0 (`status` never rewrites the index), the file-system monitor and the untracked cache off, hooks
// pointed nowhere, automatic clean-up off, a time limit and an output cap, and the whole project within one overall limit.
// Nothing here fetches, stages, checks out, commits or touches a branch or a stash. A repository whose own settings run
// programs (`filter.*`) is not read at all. Ignored folders are never walked.
public sealed class CodeBackupReader
{
  public sealed record Place(string Top, string GitDir);
  private sealed class Failure(string plain) : Exception(plain) { public string Plain { get; } = plain; }

  private readonly ICodeBackupGit git;
  private readonly string githubHost;
  private readonly int timeoutMilliseconds;
  private readonly double projectSeconds, folderSeconds;
  private readonly Func<string, bool> isDirectory;
  private readonly CodeBackupProjectCode.Bounds? bounds;
  private readonly Func<string, CodeBackupCoverage?>? coverage;

  /// Over 50 MB a file is listed as too large (GitHub refuses 100 MB).
  public const long LargeBytes = 50L * 1024 * 1024;
  /// Secret files, in three kinds (lead, 14 Nov), matched case-insensitively by the file's own name.
  /// A: real credentials. In commits GitHub does not have they HOLD BACK the branch, tag or set-aside change; their
  /// uncommitted version is left out of the copy.
  public static readonly string[] CredentialPatterns = [".env", ".env.local", ".env.*.local", ".dev.vars", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    "id_rsa_sk", "id_ecdsa_sk", "id_ed25519_sk", "*.p8", "*.p12", "*.pfx", "*.jks", "*.keystore", ".netrc", "_netrc",
    ".git-credentials", ".pypirc", "credentials", "credentials*.json", ".credentials.json", "service-account*.json",
    "*.tfstate", "*.tfstate.backup", "*.kdbx", ".pgpass", ".htpasswd", ".vault-token", "*.ppk",
    "secret.json", "secrets.json", "secret.yaml", "secrets.yaml", "secret.yml", "secrets.yml", "secret.toml",
    "secrets.toml", "secret.env", "secrets.env", "*.secret.json", "*.secrets.json", "*.secret.yaml",
    "*.secrets.yaml", "*.secret.yml", "*.secrets.yml", "*.secret.toml", "*.secrets.toml"];
  public static readonly string[] CredentialFolders = [".ssh", ".aws", ".gnupg", ".kube"];
  /// B: decided by CONTENT. A line with "PRIVATE KEY" makes it kind A; otherwise it is not secret at all.
  public static readonly string[] KeyPatterns = ["*.pem", "*.key", "*.asc"];
  /// C: left out of the uncommitted-work copy only; never holds anything back.
  public static readonly string[] LeaveOutPatterns = ["GoogleService-Info.plist", "google-services.json", ".env.*", "debug.keystore", ".npmrc", ".yarnrc.yml",
    ".envrc", "*.tfvars", "*.tfvars.json", "*.mobileprovision"];
  public static readonly string[] LeaveOutFolders = [".docker", ".azure"];
  public static IReadOnlyList<string> SecretPatterns => [.. CredentialPatterns, .. KeyPatterns, .. LeaveOutPatterns];
  public const string ExcludeMarker = "# Terminal Deck: left out of backups";
  public static string ExcludeText
  {
    get
    {
      string[] heavy = ["node_modules/", ".venv/", "venv/", "build/", "dist/", "DerivedData/", ".gradle/", "Pods/", ".next/", "target/", ".DS_Store"];
      var folders = CredentialFolders.Order(StringComparer.Ordinal).Concat(LeaveOutFolders.Order(StringComparer.Ordinal)).Select(f => f + "/");
      return ExcludeMarker + "\n" + string.Join("\n", heavy.Concat(CredentialPatterns).Concat(folders).Concat(LeaveOutPatterns)) + "\n";
    }
  }

  public enum SecretKind { None, Credential, MaybeKey, LeaveOut }

  /// `*` and `?`, case-insensitive (patterns hold no other wildcard).
  public static bool Glob(string pattern, string name)
  {
    pattern = pattern.ToLowerInvariant(); name = name.ToLowerInvariant();
    int p = 0, n = 0, star = -1, mark = 0;
    while (n < name.Length)
    {
      if (p < pattern.Length && (pattern[p] == '?' || pattern[p] == name[n])) { p++; n++; }
      else if (p < pattern.Length && pattern[p] == '*') { star = p++; mark = n; }
      else if (star >= 0) { p = star + 1; n = ++mark; }
      else return false;
    }
    while (p < pattern.Length && pattern[p] == '*') p++;
    return p == pattern.Length;
  }

  /// The kind of a path by its name alone.
  public static SecretKind KindOf(string path)
  {
    var parts = path.ToLowerInvariant().Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
    if (parts.Length == 0) return SecretKind.None;
    var name = parts[^1]; var folders = parts[..^1];
    bool Matches(IEnumerable<string> patterns) => patterns.Any(p => Glob(p, name));
    if (folders.Any(f => CredentialFolders.Contains(f))) return SecretKind.Credential;
    if (name == "debug.keystore") return SecretKind.LeaveOut;
    if (Matches(CredentialPatterns)) return SecretKind.Credential;
    if (Matches(KeyPatterns)) return SecretKind.MaybeKey;
    if (Matches(LeaveOutPatterns) || folders.Any(f => LeaveOutFolders.Contains(f))) return SecretKind.LeaveOut;
    return SecretKind.None;
  }

  public const int KeyBytes = 256 * 1024;
  public static bool PrivateKey(ReadOnlySpan<byte> data) => Encoding.UTF8.GetString(data[..Math.Min(data.Length, KeyBytes)]).Contains("PRIVATE KEY", StringComparison.Ordinal);
  public static bool PrivateKeyOnDisk(string file)
  {
    if (CodeBackupDisk.RegularSize(file) is not { } size || size > KeyBytes) return false;
    try { return PrivateKey(File.ReadAllBytes(file)); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }
  /// Left out of the uncommitted-work copy: kinds A and C, and a B file whose bytes in `top` hold a private key.
  public static bool IsSecret(string path, string? top = null) => KindOf(path) switch
  {
    SecretKind.Credential or SecretKind.LeaveOut => true,
    SecretKind.MaybeKey => top is null || PrivateKeyOnDisk(Path.Combine(top, path)),
    _ => false
  };
  /// Holds back what carries it: kind A, and a B file holding a private key. Kind C never does.
  public static bool HoldsBack(string path, string? top = null) => KindOf(path) switch
  {
    SecretKind.Credential => true,
    SecretKind.MaybeKey => top is null || PrivateKeyOnDisk(Path.Combine(top, path)),
    _ => false
  };

  public static readonly string[] ReadOnlyFlags = ["-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false"];
  public const string RunsPrograms = "this folder's Git settings run programs";
  public const string Slow = "the folder took too long to read";
  public const string Silent = "the folder did not answer";

  public CodeBackupReader(ICodeBackupGit git, string githubHost = "github.com", int timeoutMilliseconds = 15_000, double projectSeconds = 30, double folderSeconds = 5,
    Func<string, bool>? isDirectory = null, CodeBackupProjectCode.Bounds? bounds = null, Func<string, CodeBackupCoverage?>? coverage = null)
  {
    this.git = git; this.githubHost = githubHost.ToLowerInvariant(); this.timeoutMilliseconds = timeoutMilliseconds;
    this.projectSeconds = projectSeconds; this.folderSeconds = folderSeconds; this.isDirectory = isDirectory ?? Directory.Exists;
    this.bounds = bounds; this.coverage = coverage;
  }

  private static readonly IReadOnlyDictionary<string, string> NoEnvironment = new Dictionary<string, string>();
  private CodeBackupProjectCode.Probe ProbeFor() => async (cwd, arguments) =>
  {
    var outcome = await git.RunAsync(cwd, [.. ReadOnlyFlags, .. arguments], NoEnvironment, timeoutMilliseconds, 64 * 1024);
    return outcome.Missing ? null : outcome.Output;
  };

  private async Task<CodeProcessResult> Git(string cwd, IReadOnlyList<string> arguments, CancellationToken ct, int maximum = 16 * 1024 * 1024)
  {
    ct.ThrowIfCancellationRequested();
    var outcome = await git.RunAsync(cwd, [.. ReadOnlyFlags, .. arguments], NoEnvironment, timeoutMilliseconds, maximum, ct);
    if (outcome.Missing) throw new Failure("Git is not installed on this PC");
    if (outcome.TimedOut) throw new Failure(Slow);
    return outcome;
  }
  private static string Trim(CodeProcessResult r) => r.Output.Trim();
  private static string Leaf(string path) => Path.GetFileName(Path.TrimEndingDirectorySeparator(path)) is { Length: > 0 } leaf ? leaf : path;

  /// Every code folder of the project that Git keeps, each read on its own; the project shows the worst of them.
  public async Task<(CodeBackupProject Row, IReadOnlyList<Place> Places)> Read(CodeBackupProjectRef project)
  {
    var row = new CodeBackupProject(project.Id, project.Name);
    var candidates = project.Folders.Where(f => !string.IsNullOrWhiteSpace(f) && Path.IsPathFullyQualified(f)).ToList();
    if (candidates.Count == 0) return (row, []);
    var present = await CodeBackupDisk.Folders(candidates, folderSeconds, isDirectory);
    if (present is null) { row.HasFolder = true; row.FolderName = Leaf(candidates[0]); row.Problem = Silent; return (row, []); }
    if (present.Count == 0) return (row, []);
    using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(projectSeconds));
    var work = ReadFolders(project, present, limit.Token);
    var winner = await Task.WhenAny(work, Task.Delay(TimeSpan.FromSeconds(projectSeconds)));
    if (winner != work) { limit.Cancel(); row.HasFolder = true; row.FolderName = Leaf(present[0]); row.Problem = Slow; return (row, []); }
    return await work;
  }

  private async Task<(CodeBackupProject, IReadOnlyList<Place>)> ReadFolders(CodeBackupProjectRef project, IReadOnlyList<string> folders, CancellationToken ct)
  {
    var places = new List<Place>(); var parts = new List<CodeBackupProject>();
    var fence = bounds ?? CodeBackupProjectCode.Bounds.Live();
    var waiting = new Queue<(string Path, int Depth, bool Given)>(folders.Select(f => (f, 0, true)));
    var several = folders.Count > 1;
    while (waiting.Count > 0)
    {
      var (folder, depth, given) = waiting.Dequeue();
      var part = new CodeBackupProject(Leaf(folder), project.Name) { HasFolder = true };
      part.FolderName = part.Id;
      try
      {
        if (given && CodeBackupProjectCode.WaitingForCode(folder, fence)) { if (several) parts.Add(part); continue; }
        var found = await Git(folder, ["rev-parse", "--show-toplevel", "--absolute-git-dir"], ct);
        var lines = found.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).ToArray();
        if (!found.Ok || lines.Length < 2)
        {
          if (found.Error.Contains("not a git repository", StringComparison.OrdinalIgnoreCase)) { if (several && given) parts.Add(part); continue; }
          throw new Failure("Git could not read the folder");
        }
        var top = CodeBackupProjectCode.Resolved(lines[0]);
        if (!await CodeBackupProjectCode.Owns(top, folder, fence, ProbeFor())) { if (several && given) parts.Add(part); continue; }
        var place = new Place(top, CodeBackupProjectCode.Resolved(lines[1]));
        if (places.Contains(place)) continue;
        places.Add(place);
        part.Id = Leaf(place.Top); part.FolderName = part.Id; part.IsRepository = true;
        await Fill(part, place.Top, place.GitDir, ct);
        if (depth < 2) foreach (var sub in await Submodules(place.Top, ct)) waiting.Enqueue((sub, depth + 1, false));
        if (depth == 0) foreach (var nested in await NestedRepositories(place.Top)) waiting.Enqueue((nested, 1, false));
      }
      catch (Failure failure) { part.Problem = failure.Plain; }
      catch (OperationCanceledException) { part.Problem = Slow; }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { part.Problem = "Git could not be started"; }
      if (part.IsRepository || part.Problem is not null) parts.Add(part);
    }
    if (parts.Count == 0)
    {
      var row = new CodeBackupProject(project.Id, project.Name) { HasFolder = true, FolderName = Leaf(folders[0]) };
      row.WaitingForCode = !several && CodeBackupProjectCode.WaitingForCode(folders[0], fence);
      return (row, places);
    }
    return (CodeBackupProject.Combine(project.Id, project.Name, parts), places);
  }

  private async Task RefuseProgramSettings(string top, CancellationToken ct, int depth = 0)
  {
    var filters = await Git(top, ["config", "--show-scope", "--includes", "--get-regexp", @"^filter\..*\.(clean|smudge|process)$"], ct);
    if (filters.Ok && RepositoryRunsPrograms(filters.Output)) throw new Failure(RunsPrograms);
    if (depth >= 3) return;
    foreach (var sub in await Submodules(top, ct)) await RefuseProgramSettings(sub, ct, depth + 1);
  }

  private async Task<List<string>> Submodules(string top, CancellationToken ct)
  {
    var entries = await Git(top, ["ls-files", "-s", "-z"], ct, 32 * 1024 * 1024);
    if (!entries.Ok) return [];
    var paths = Gitlinks(entries.Output).Select(p => Path.GetFullPath(Path.Combine(top, p))).ToList();
    var present = await CodeBackupDisk.Run(folderSeconds, () => paths.Where(p => CodeBackupDisk.Exists(Path.Combine(p, ".git"))).ToList());
    if (!present.Done) throw new Failure(Silent);
    return present.Value;
  }

  private async Task<List<string>> NestedRepositories(string top)
  {
    var found = await CodeBackupDisk.Run(folderSeconds, () => Nested(top));
    return found.Done ? found.Value : [];
  }

  /// Git repositories in the top two levels of a repository's folder that are not that repository.
  public static List<string> Nested(string top)
  {
    IEnumerable<string> Children(string path)
    {
      try { return Directory.EnumerateDirectories(path).Where(c => !string.Equals(Path.GetFileName(c), ".git", StringComparison.OrdinalIgnoreCase) && CodeBackupDisk.RealFolder(c)).ToList(); }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
    }
    var found = new List<string>();
    foreach (var child in Children(top))
    {
      if (CodeBackupDisk.Exists(Path.Combine(child, ".git"))) { found.Add(child); continue; }
      foreach (var grandchild in Children(child).Take(5_000)) if (CodeBackupDisk.Exists(Path.Combine(grandchild, ".git"))) found.Add(grandchild);
    }
    return found.Order(StringComparer.Ordinal).ToList();
  }

  /// `ls-files -s -z`: "160000 <object> <stage>\t<path>\0" for a submodule.
  public static List<string> Gitlinks(string text) =>
    text.Split('\0', StringSplitOptions.RemoveEmptyEntries).Where(e => e.StartsWith("160000 ", StringComparison.Ordinal) && e.Contains('\t')).Select(e => e[(e.IndexOf('\t') + 1)..]).ToList();

  private async Task Fill(CodeBackupProject row, string top, string gitDir, CancellationToken ct)
  {
    await RefuseProgramSettings(top, ct);
    var branch = await Git(top, ["symbolic-ref", "--quiet", "--short", "HEAD"], ct);
    row.Branch = branch.Ok ? Trim(branch) : null;
    var head = await Git(top, ["log", "-1", "--format=%ct%x1f%H", "HEAD"], ct);
    var headParts = Trim(head).Split('\u001f');
    if (head.Ok && long.TryParse(headParts[0], out var seconds)) row.LastCommitAt = seconds * 1000;
    var headCommit = head.Ok && headParts.Length > 1 ? headParts[1] : "";
    var remotes = await Git(top, ["config", "--get-regexp", @"^remote\..*\.url$"], ct);
    var addresses = Remotes(remotes.Ok ? remotes.Output : "");
    var chosen = addresses.FirstOrDefault(a => a.Name == "origin") ?? addresses.FirstOrDefault();
    if (chosen is not null)
    {
      if (GitHubHome(chosen.Url, githubHost) is { } home) row.Home = home; else row.OtherHost = Host(chosen.Url) ?? "another place";
    }
    var status = await Git(top, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--no-renames"], ct);
    if (!status.Ok) throw new Failure("Git could not read the folder");
    var changed = StatusNames(status.Output);
    row.ChangedCount = changed.Count;
    row.ChangedFiles = changed.Take(CodeBackupProject.ListLimit).ToList();
    var stash = await Git(top, ["log", "--walk-reflogs", "--format=%H", "refs/stash"], ct);
    var stashes = stash.Ok ? stash.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).ToList() : [];
    row.SetAsideCount = stashes.Count;
    var covered = coverage?.Invoke(gitDir);
    if (covered is not null)
    {
      var raw = status.Output;
      if (changed.Count > 0)
      {
        var now = await CodeBackupDisk.Run(projectSeconds, () => CodeBackupCoverage.MakeFingerprint(headCommit, raw, top));
        if (now.Done && covered.Fingerprint == now.Value) row.ChangesCoveredAt = covered.At;
      }
      if (stashes.Count > 0 && stashes.All(covered.Stashes.Contains)) row.SetAsideCovered = true;
    }
    var keptHeads = (covered?.Heads ?? []).Values.Distinct().Order(StringComparer.Ordinal).ToList();
    if (chosen is not null && row.LastCommitAt is not null) await Pushed(row, top, chosen.Name, keptHeads, ct);
    var files = await Git(top, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], ct, 32 * 1024 * 1024);
    if (!files.Ok) throw new Failure("Git could not list the folder's files");
    var committed = new HashSet<string>(StringComparer.Ordinal);
    if (row.LastCommitAt is not null)
    {
      var tree = await Git(top, ["ls-tree", "-r", "-z", "--name-only", "HEAD"], ct, 32 * 1024 * 1024);
      if (!tree.Ok) throw new Failure("Git could not list the folder's files");
      committed = tree.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
    }
    var names = files.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
    var sorted = await CodeBackupDisk.Run(projectSeconds, () => HeldFiles(names, committed, top));
    if (!sorted.Done) throw new Failure(Silent);
    row.Held = sorted.Value.Held; row.SecretsInCommits = sorted.Value.InCommits;
  }

  private async Task Pushed(CodeBackupProject row, string top, string remote, IReadOnlyList<string> kept, CancellationToken ct)
  {
    var present = new List<string>();
    foreach (var sha in kept.Take(200)) if ((await Git(top, ["cat-file", "-e", sha + "^{commit}"], ct)).Ok) present.Add(sha);
    var known = await Git(top, ["for-each-ref", "--format=%(objectname)", "refs/remotes/" + remote], ct);
    var heard = known.Ok && Trim(known).Length > 0;
    if (!heard && present.Count == 0)
    {
      var count = await Git(top, ["rev-list", "--count", "--branches", "HEAD"], ct);
      row.CommitCount = int.TryParse(Trim(count), out var c) ? c : 0;
      if (row.CommitCount > 0) row.Commits = await CommitList(top, ["--branches", "HEAD"], ct);
      return;
    }
    var tips = await Git(top, ["for-each-ref", "--format=%(objectname)%1f%(committerdate:unix)%1f%(refname:strip=2)", "refs/heads"], ct);
    var heads = tips.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim().Split('\u001f')).Where(p => p.Length == 3 && long.TryParse(p[1], out _))
      .Select(p => (Sha: p[0], At: long.Parse(p[1], System.Globalization.CultureInfo.InvariantCulture) * 1000, Name: p[2])).ToList();
    var walk = await Git(top, ["log", "--boundary", "--branches", "HEAD", "--not", "--remotes=" + remote, .. present, "--format=%m%x1f%H%x1f%ct%x1f%s"], ct, 32 * 1024 * 1024);
    if (!walk.Ok) throw new Failure("Git could not read the commits");
    var missing = new List<CodeBackupCommit>(); var missingShas = new HashSet<string>(StringComparer.Ordinal); long? newest = null;
    foreach (var line in walk.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      var parts = line.TrimEnd('\r').Split('\u001f', 4);
      if (parts.Length < 3 || !long.TryParse(parts[2], out var seconds)) continue;
      if (parts[0] == "-") newest = Math.Max(newest ?? 0, seconds * 1000);
      else if (missingShas.Add(parts[1])) missing.Add(new(parts.Length > 3 ? parts[3] : "", seconds * 1000));
    }
    foreach (var head in heads.Where(h => !missingShas.Contains(h.Sha))) newest = Math.Max(newest ?? 0, head.At);
    row.LastBackedUpAt = newest;
    row.CommitCount = missing.Count;
    row.Commits = missing.OrderByDescending(m => m.At).Take(CodeBackupProject.ListLimit).ToList();
    if (present.Count == 0) return;
    var all = await Git(top, ["rev-list", "--count", "--branches", "HEAD", "--not", "--remotes=" + remote], ct);
    row.PrivateCommitCount = Math.Max(0, (int.TryParse(Trim(all), out var a) ? a : 0) - missing.Count);
    if (row.PrivateCommitCount == 0) return;
    foreach (var head in heads.Where(h => !missingShas.Contains(h.Sha)))
    {
      var ahead = await Git(top, ["rev-list", "--count", head.Sha, "--not", "--remotes=" + remote], ct);
      if ((int.TryParse(Trim(ahead), out var n) ? n : 0) > 0) row.PrivateBranches.Add(head.Name);
    }
  }

  private async Task<List<CodeBackupCommit>> CommitList(string top, IReadOnlyList<string> range, CancellationToken ct)
  {
    var log = await Git(top, ["log", .. range, "-n", CodeBackupProject.ListLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), "--format=%ct%x1f%s"], ct);
    if (!log.Ok) return [];
    return log.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.TrimEnd('\r').Split('\u001f', 2))
      .Where(p => long.TryParse(p[0], out _)).Select(p => new CodeBackupCommit(p.Length > 1 ? p[1] : "", long.Parse(p[0], System.Globalization.CultureInfo.InvariantCulture) * 1000)).ToList();
  }

  // ---- plain parsing (tested directly) ----

  /// `config --show-scope --get-regexp`: "<scope>\t<key> <value>" per line.
  public static bool RepositoryRunsPrograms(string text) =>
    text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Any(line => line.Split('\t', 2)[0] is "local" or "worktree");

  public sealed record Remote(string Name, string Url);
  public static List<Remote> Remotes(string text) =>
    text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.TrimEnd('\r').Split(' ', 2)).Where(p => p.Length == 2 && p[0].StartsWith("remote.", StringComparison.Ordinal) && p[0].EndsWith(".url", StringComparison.Ordinal))
      .Select(p => new Remote(p[0]["remote.".Length..^".url".Length], p[1].Trim())).ToList();

  /// "owner/name" for https://github.com/o/n(.git), git@github.com:o/n.git, ssh://git@github.com/o/n.git.
  public static string? GitHubHome(string url, string host)
  {
    string rest;
    var scheme = url.IndexOf("://", StringComparison.Ordinal);
    if (scheme >= 0)
    {
      var after = url[(scheme + 3)..];
      var slash = after.IndexOf('/');
      if (slash < 0) return null;
      var authority = after[..slash].Split('@')[^1];
      if (!string.Equals(authority.Split(':')[0], host, StringComparison.OrdinalIgnoreCase)) return null;
      rest = after[(slash + 1)..];
    }
    else if (url.IndexOf(':') is var colon and > 0 && !url[..colon].Contains('/') && !url[..colon].Contains('\\') && colon > 1)
    {
      if (!string.Equals(url[..colon].Split('@')[^1], host, StringComparison.OrdinalIgnoreCase)) return null;
      rest = url[(colon + 1)..];
    }
    else return null;
    if (rest.EndsWith('/')) rest = rest[..^1];
    if (rest.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) rest = rest[..^4];
    var parts = rest.Split('/', StringSplitOptions.RemoveEmptyEntries);
    return parts.Length == 2 ? parts[0] + "/" + parts[1] : null;
  }

  public static string? Host(string url)
  {
    var scheme = url.IndexOf("://", StringComparison.Ordinal);
    if (scheme >= 0)
    {
      if (url.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) return "a folder on this PC";
      var authority = url[(scheme + 3)..].Split('/')[0];
      return authority.Split('@')[^1].Split(':')[0];
    }
    if (url.StartsWith('/') || url.StartsWith('.') || url.StartsWith('\\') || (url.Length > 2 && url[1] == ':' && (url[2] == '\\' || url[2] == '/'))) return "a folder on this PC";
    var colon = url.IndexOf(':');
    return colon > 0 ? url[..colon].Split('@')[^1] : null;
  }

  /// `status --porcelain=v1 -z --no-renames`: "XY name\0" per entry.
  public static List<string> StatusNames(string text) =>
    text.Split('\0', StringSplitOptions.RemoveEmptyEntries).Where(e => e.Length > 3).Select(e => e[3..]).ToList();

  /// Files not in the last commit that cannot go as they are, and secret files that are in it.
  public static (List<CodeBackupHeld> Held, List<string> InCommits) HeldFiles(IReadOnlySet<string> names, IReadOnlySet<string> committed, string top)
  {
    var held = new List<CodeBackupHeld>();
    foreach (var name in names.Order(StringComparer.Ordinal).Where(n => !committed.Contains(n)))
    {
      if (IsSecret(name, top)) { held.Add(new(name, CodeBackupHeldReason.LooksSecret)); continue; }
      if (CodeBackupDisk.RegularSize(Path.Combine(top, name)) is { } size && size > LargeBytes) held.Add(new(name, CodeBackupHeldReason.TooLarge));
    }
    return (held, committed.Where(c => HoldsBack(c, top)).Order(StringComparer.Ordinal).ToList());
  }
}

/// Private or public, from GitHub, only when this PC is signed in to it.
public interface ICodeBackupGitHubReading
{
  Task<CodeBackupGitHubAnswer> Visibility(IReadOnlySet<string> homes);
}
public sealed record CodeBackupGitHubAnswer(bool SignedIn, IReadOnlyDictionary<string, CodeBackupVisibility> Found)
{
  public static CodeBackupGitHubAnswer SignedOut { get; } = new(false, new Dictionary<string, CodeBackupVisibility>());
}

/// The live reader: the repositories the sign-in already lists, then each home not in that list, all at once.
public sealed class CodeBackupGitHub(ICodeBackupAccount account) : ICodeBackupGitHubReading
{
  public async Task<CodeBackupGitHubAnswer> Visibility(IReadOnlySet<string> homes)
  {
    if (await account.Login() is null) return CodeBackupGitHubAnswer.SignedOut;
    var listed = (await account.Repositories()).ToDictionary(r => r.NameWithOwner.ToLowerInvariant(), r => r.IsPrivate);
    var found = new Dictionary<string, CodeBackupVisibility>();
    var missing = new List<string>();
    foreach (var home in homes.Select(h => h.ToLowerInvariant()).Distinct().Order(StringComparer.Ordinal))
    {
      if (listed.TryGetValue(home, out var isPrivate)) found[home] = isPrivate ? CodeBackupVisibility.Private : CodeBackupVisibility.Public; else missing.Add(home);
    }
    var answers = await Task.WhenAll(missing.Take(50).Select(async home => (home, repo: await account.Repository(home))));
    foreach (var (home, repo) in answers) if (repo is not null) found[home] = repo.IsPrivate ? CodeBackupVisibility.Private : CodeBackupVisibility.Public;
    return new(true, found);
  }
}

/// The Code page's model: every project on this PC, read off the UI thread, at most four at a time. A project's answer is
/// kept until Refresh, a change Git records (a commit, a push, staging, a stash, a branch switch), or a minute passes.
/// GitHub's private/public answers are kept apart and never hold the Git facts back.
public sealed class CodeBackupProjects(Func<Task<IReadOnlyList<CodeBackupProjectRef>>> projects, CodeBackupReader reader, ICodeBackupGitHubReading github,
  Func<DateTimeOffset>? now = null, double maxAgeSeconds = 60, double githubSeconds = 4)
{
  private sealed record Kept(CodeBackupProjectRef Project, CodeBackupProject Row, IReadOnlyList<CodeBackupReader.Place> Places, string Mark, DateTimeOffset At);
  private readonly Func<DateTimeOffset> clock = now ?? (() => DateTimeOffset.UtcNow);
  private readonly object gate = new();
  private readonly Dictionary<string, Kept> kept = [];
  private Task<CodeBackupReport>? running;
  private Dictionary<string, CodeBackupVisibility> visibility = [];
  private bool? signedIn;
  private (DateTimeOffset At, HashSet<string> Homes)? askedGitHub;
  private Task? asking;

  /// The Git facts at once, with the private/public answers kept so far. Never fails.
  public async Task<CodeBackupReport> Report(bool refresh = false)
  {
    Task<CodeBackupReport> task;
    lock (gate)
    {
      if (refresh) { kept.Clear(); askedGitHub = null; }
      task = running ??= Build();
    }
    var report = await task;
    lock (gate) if (running == task) running = null;
    return Applied(report);
  }

  /// The same report once GitHub has answered, waiting at most `githubSeconds` in all.
  public async Task<CodeBackupReport> WithGitHub(CodeBackupReport report)
  {
    var homes = report.Projects.SelectMany(p => p.Homes).Select(h => h.ToLowerInvariant()).ToHashSet();
    Task task;
    lock (gate)
    {
      if (askedGitHub is { } asked && (clock() - asked.At).TotalSeconds < 300 && homes.IsSubsetOf(asked.Homes)) return Applied(report);
      task = asking ??= Task.Run(async () => { var answer = await github.Visibility(homes); Keep(answer, homes); });
    }
    await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(githubSeconds)));
    return Applied(report);
  }

  public async Task<IReadOnlyList<CodeBackupProjectRef>> List()
  {
    try { return await projects(); } catch (Exception error) when (error is IOException or InvalidOperationException) { return []; }
  }
  /// One project read now, never from the kept answers (before and for an action).
  public Task<(CodeBackupProject Row, IReadOnlyList<CodeBackupReader.Place> Places)> Fresh(CodeBackupProjectRef project) => reader.Read(project);
  /// After an action, the next look reads the project again.
  public void Forget(string projectId) { lock (gate) kept.Remove(projectId); }

  private void Keep(CodeBackupGitHubAnswer answer, HashSet<string> homes)
  {
    lock (gate)
    {
      signedIn = answer.SignedIn;
      if (answer.SignedIn) foreach (var (k, v) in answer.Found) visibility[k] = v; else visibility = [];
      askedGitHub = (clock(), homes); asking = null;
    }
  }

  private CodeBackupReport Applied(CodeBackupReport report)
  {
    lock (gate) return new(report.Projects.Select(p => p.Filling(visibility)), signedIn, report.CheckedAt);
  }

  private async Task<CodeBackupReport> Build()
  {
    await Task.Yield();
    var list = await List();
    var started = clock();
    var rows = new List<CodeBackupProject>(); var toRead = new List<CodeBackupProjectRef>();
    foreach (var project in list)
    {
      Kept? old; lock (gate) kept.TryGetValue(project.Id, out old);
      if (old is not null && old.Project.Same(project) && (started - old.At).TotalSeconds < maxAgeSeconds && await MarkOnQueue(project, old.Places) is { } mark && mark == old.Mark) rows.Add(old.Row);
      else toRead.Add(project);
    }
    using var four = new SemaphoreSlim(4);
    var results = await Task.WhenAll(toRead.Select(async project =>
    {
      await four.WaitAsync();
      try { var (row, places) = await reader.Read(project); return (project, row, places); }
      finally { four.Release(); }
    }));
    foreach (var (project, row, places) in results)
    {
      rows.Add(row);
      var mark = row.Problem is null ? await MarkOnQueue(project, places) : null;
      lock (gate) { if (mark is not null) kept[project.Id] = new(project, row, places, mark, started); else kept.Remove(project.Id); }
    }
    bool? known; lock (gate) known = signedIn;
    return new(rows, known, started.ToUnixTimeMilliseconds());
  }

  public static async Task<string?> MarkOnQueue(CodeBackupProjectRef project, IReadOnlyList<CodeBackupReader.Place> places)
  {
    if (project.Folders.Any(CodeBackupDisk.RecentlyHung)) return null;
    var mark = await CodeBackupDisk.Run(3, () => Mark(project, places));
    if (!mark.Done) { CodeBackupDisk.NoteHung(project.Folders); return null; }
    return mark.Value;
  }

  /// What changes when Git records something: the folders, and the modification times of HEAD, the staging area, the
  /// packed refs, the reflogs (a stash too) and the remote refs. A look each, never a Git command.
  public static string Mark(CodeBackupProjectRef project, IReadOnlyList<CodeBackupReader.Place> places)
  {
    var mark = new StringBuilder();
    foreach (var folder in project.Folders) mark.Append(folder).Append(Directory.Exists(folder) ? "+|" : "-|");
    foreach (var place in places)
    {
      foreach (var name in new[] { "HEAD", "index", "packed-refs", "FETCH_HEAD", "logs/HEAD", "refs/stash" }) mark.Append(CodeBackupDisk.Stamp(Path.Combine(place.GitDir, name))).Append('|');
      foreach (var folder in new[] { "refs/heads", "refs/remotes", "logs/refs" })
      {
        var root = Path.Combine(place.GitDir, folder);
        mark.Append(CodeBackupDisk.Stamp(root)).Append('|');
        if (!Directory.Exists(root)) continue;
        try
        {
          var count = 0;
          foreach (var item in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
          {
            if (count++ >= 2_000) break;
            mark.Append(Path.GetRelativePath(root, item)).Append('@').Append(CodeBackupDisk.Stamp(item)).Append('|');
          }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { mark.Append("?|"); }
      }
    }
    return mark.ToString();
  }
}
