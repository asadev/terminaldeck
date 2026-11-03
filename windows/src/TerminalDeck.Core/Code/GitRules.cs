using System.Globalization;

namespace TerminalDeck.Core.Code;

// Source control's pure half, rule for rule with the Mac's GitRules.swift, plus
// the parsers for the system git's porcelain output.
public enum GitFileGroup { Staged, Unstaged, Untracked, Conflicted }
public enum GitChangeKind { Added, Modified, Deleted, Renamed, Copied, Typechange, Untracked, Conflicted, Unknown }
public sealed record GitFile(string Path, GitFileGroup Group, GitChangeKind Kind, string Code = " M", string? OrigPath = null, int? Insertions = null, int? Deletions = null, bool Binary = false)
{
  public string Id => Group.ToString().ToLowerInvariant() + ":" + Path;
}
public sealed record GitBranch(string? Name, bool Detached = false, string? Oid = null, string? Upstream = null, int Ahead = 0, int Behind = 0)
{
  public string Label => Detached ? "detached at " + (Oid is { Length: > 0 } oid ? oid[..Math.Min(7, oid.Length)] : "unknown") : Name ?? "no branch";
}
public enum GitUnavailableReason { NotARepo, GitMissing, NoSuchFolder, Error }
public sealed record GitRepoStatus(string Cwd, string Root, GitBranch Branch, IReadOnlyList<GitFile> Staged, IReadOnlyList<GitFile> Unstaged, IReadOnlyList<GitFile> Untracked, IReadOnlyList<GitFile> Conflicted)
{
  public bool Clean => Staged.Count + Unstaged.Count + Untracked.Count + Conflicted.Count == 0;
  public int ChangeCount => Staged.Count + Unstaged.Count + Untracked.Count + Conflicted.Count;
}
public sealed record GitStatusResult(GitRepoStatus? Repo, string Cwd, GitUnavailableReason Reason = GitUnavailableReason.Error, string Message = "", bool CanInit = false);
public sealed record GitGroup(GitFileGroup Key, string Label, IReadOnlyList<GitFile> Files);
public enum GitDiffLineKind { Add, Del, Hunk, Meta, Context }
public sealed record GitDiffLine(GitDiffLineKind Kind, string Text);
public sealed record GitUnavailableView(string Title, string Message, bool CanInit);
public sealed record GitCommitInfo(string Oid, string Short, string Author, string When, string Subject);
public sealed record GitBranchRef(string Name, bool Current, bool Remote, string? Upstream);

public static class GitRules
{
  public const int MaxRowsPerGroup = 500;
  public const int MaxDiffLines = 2000;
  public const string MissingMessage = "Install Git for Windows (git-scm.com), then refresh. Terminal Deck uses your own git and never stores a password.";

  public static string ChangeLabel(GitChangeKind kind, string code)
  {
    var word = kind switch
    {
      GitChangeKind.Added => "Added", GitChangeKind.Modified => "Modified", GitChangeKind.Deleted => "Deleted", GitChangeKind.Renamed => "Renamed",
      GitChangeKind.Copied => "Copied", GitChangeKind.Typechange => "Type", GitChangeKind.Untracked => "Untracked", GitChangeKind.Conflicted => "Conflict", _ => ""
    };
    if (word.Length > 0) return word;
    var trimmed = code.Trim(); return trimmed.Length == 0 ? "?" : trimmed;
  }
  public static string GroupState(GitFileGroup group) => group switch
  {
    GitFileGroup.Conflicted => "needs resolving", GitFileGroup.Staged => "ready to commit", GitFileGroup.Unstaged => "not staged yet", _ => "not tracked yet"
  };
  public static string UnavailableTitle(GitUnavailableReason reason) => reason switch
  {
    GitUnavailableReason.NotARepo => "Nothing to track here", GitUnavailableReason.GitMissing => "git is not installed",
    GitUnavailableReason.NoSuchFolder => "That folder is gone", _ => "Source control is unavailable"
  };
  public static GitUnavailableView Unavailable(GitStatusResult? status)
  {
    if (status is null || status.Repo is not null) return new(UnavailableTitle(GitUnavailableReason.Error), "git could not read this folder", false);
    return new(UnavailableTitle(status.Reason), status.CanInit ? "This folder is not a git repository." : status.Message, status.CanInit);
  }
  public static IReadOnlyList<GitGroup> Groups(GitRepoStatus status) => new[]
  {
    new GitGroup(GitFileGroup.Conflicted, "Conflicts", status.Conflicted), new GitGroup(GitFileGroup.Staged, "Staged", status.Staged),
    new GitGroup(GitFileGroup.Unstaged, "Changes", status.Unstaged), new GitGroup(GitFileGroup.Untracked, "Untracked", status.Untracked)
  }.Where(g => g.Files.Count > 0).ToArray();
  public static string BaseName(string path)
  {
    var folder = path.EndsWith('/'); var trimmed = folder ? path[..^1] : path;
    var cut = trimmed.LastIndexOf('/'); return cut < 0 ? path : trimmed[(cut + 1)..] + (folder ? "/" : "");
  }
  public static string DirName(string path)
  {
    var trimmed = path.EndsWith('/') ? path[..^1] : path; var cut = trimmed.LastIndexOf('/');
    return cut < 0 ? "" : trimmed[..cut];
  }
  public static string Describe(GitFile file) => file.OrigPath is { } orig ? orig + " → " + file.Path : file.Path;
  public static string RowDetail(GitFile file) => file.OrigPath is { } orig ? "← " + orig : DirName(file.Path);
  public static string RowTitle(GitFile file) { var code = file.Code.Trim(); return $"{Describe(file)} — git status {(code.Length == 0 ? "?" : code)}"; }
  public static string? NoDiffReason(GitFile file)
  {
    if (file.Path.EndsWith('/')) return "This is a folder git has not looked inside yet — it lists the whole folder as one untracked entry. Commit or ignore it and the files inside get their own rows.";
    return file.Binary ? "A binary file. There is no text to line up side by side." : null;
  }
  public static string? FirstChoice(IReadOnlyList<GitGroup> groups)
  {
    var rows = groups.SelectMany(g => g.Files).ToArray();
    return (rows.FirstOrDefault(r => NoDiffReason(r) is null) ?? rows.FirstOrDefault())?.Path;
  }
  public static string DiffMeta(GitFile file, GitFileGroup group)
  {
    var parts = new List<string> { ChangeLabel(file.Kind, file.Code) + " · " + GroupState(group) };
    if (file.Binary) parts.Add("binary");
    else
    {
      var counts = string.Join(" ", new[] { file.Insertions is > 0 ? "+" + file.Insertions : null, file.Deletions is > 0 ? "−" + file.Deletions : null }.OfType<string>());
      if (counts.Length > 0) parts.Add(counts);
    }
    return string.Join(" · ", parts);
  }
  public static string MoreLines(int count) => count.ToString("N0", CultureInfo.InvariantCulture) + " more lines not shown.";
  public static string NoTextChange(GitFileGroup group) => $"git reports no text change for this file where it is — {GroupState(group)}. Its counterpart in another group may hold the change.";

  public static IReadOnlyList<GitDiffLine> ParseUnifiedDiff(string text)
  {
    if (string.IsNullOrEmpty(text)) return [];
    var raw = text.Replace("\r\n", "\n").Split('\n').ToList();
    if (raw[^1].Length == 0) raw.RemoveAt(raw.Count - 1);
    int old = 0, @new = 0;
    static int Count(string field) { var parts = field.Split(','); return parts.Length > 1 && int.TryParse(parts[1], out var n) ? n : 1; }
    var result = new List<GitDiffLine>(raw.Count);
    foreach (var line in raw)
    {
      if (old > 0 || @new > 0)
      {
        if (line.StartsWith('\\')) { result.Add(new(GitDiffLineKind.Meta, line)); continue; }
        if (line.StartsWith('+')) { @new--; result.Add(new(GitDiffLineKind.Add, line[1..])); continue; }
        if (line.StartsWith('-')) { old--; result.Add(new(GitDiffLineKind.Del, line[1..])); continue; }
        if (line.StartsWith(' ') || line.Length == 0) { old--; @new--; result.Add(new(GitDiffLineKind.Context, line.Length == 0 ? "" : line[1..])); continue; }
        old = 0; @new = 0;
      }
      if (line.StartsWith("@@", StringComparison.Ordinal))
      {
        var fields = line.Split(' ');
        if (fields.Length >= 3 && fields[1].StartsWith('-') && fields[2].StartsWith('+')) { old = Count(fields[1]); @new = Count(fields[2]); }
        result.Add(new(GitDiffLineKind.Hunk, line)); continue;
      }
      if (new[] { "+++", "---", "diff ", "index ", "\\", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode" }.Any(p => line.StartsWith(p, StringComparison.Ordinal)))
      { result.Add(new(GitDiffLineKind.Meta, line)); continue; }
      if (line.StartsWith('+')) result.Add(new(GitDiffLineKind.Add, line[1..]));
      else if (line.StartsWith('-')) result.Add(new(GitDiffLineKind.Del, line[1..]));
      else result.Add(new(GitDiffLineKind.Context, line.StartsWith(' ') ? line[1..] : line));
    }
    return result;
  }

  private static GitChangeKind Kind(char letter) => letter switch
  {
    'A' => GitChangeKind.Added, 'M' => GitChangeKind.Modified, 'D' => GitChangeKind.Deleted, 'R' => GitChangeKind.Renamed,
    'C' => GitChangeKind.Copied, 'T' => GitChangeKind.Typechange, _ => GitChangeKind.Unknown
  };

  // `git status --porcelain=v2 --branch -z`.
  public static GitRepoStatus ParseStatus(string cwd, string root, string porcelain)
  {
    string? oid = null, head = null, upstream = null; int ahead = 0, behind = 0; var detached = false;
    var staged = new List<GitFile>(); var unstaged = new List<GitFile>(); var untracked = new List<GitFile>(); var conflicted = new List<GitFile>();
    var fields = porcelain.Split('\0');
    for (var i = 0; i < fields.Length; i++)
    {
      var line = fields[i];
      if (line.Length == 0) continue;
      if (line.StartsWith("# ", StringComparison.Ordinal))
      {
        var parts = line[2..].Split(' ', 2); var value = parts.Length > 1 ? parts[1] : "";
        switch (parts[0])
        {
          case "branch.oid": oid = value == "(initial)" ? null : value; break;
          case "branch.head": if (value == "(detached)") detached = true; else head = value; break;
          case "branch.upstream": upstream = value; break;
          case "branch.ab":
            var ab = value.Split(' ');
            if (ab.Length == 2) { int.TryParse(ab[0].TrimStart('+'), out ahead); int.TryParse(ab[1].TrimStart('-'), out behind); }
            break;
        }
        continue;
      }
      switch (line[0])
      {
        case '1':
        case '2':
          {
            var count = line[0] == '1' ? 9 : 10;
            var parts = line.Split(' ', count);
            if (parts.Length < count) break;
            var xy = parts[1]; var path = parts[count - 1];
            string? orig = null;
            if (line[0] == '2' && i + 1 < fields.Length) orig = fields[++i];
            if (xy[0] != '.') staged.Add(new(path, GitFileGroup.Staged, Kind(xy[0]), xy, orig));
            if (xy[1] != '.') unstaged.Add(new(path, GitFileGroup.Unstaged, Kind(xy[1]), xy, line[0] == '2' && xy[0] == '.' ? orig : null));
            break;
          }
        case 'u':
          {
            var parts = line.Split(' ', 11);
            if (parts.Length == 11) conflicted.Add(new(parts[10], GitFileGroup.Conflicted, GitChangeKind.Conflicted, parts[1]));
            break;
          }
        case '?':
          untracked.Add(new(line[2..], GitFileGroup.Untracked, GitChangeKind.Untracked, "??")); break;
      }
    }
    return new(cwd, root, new(head, detached, oid, upstream, ahead, behind), staged, unstaged, untracked, conflicted);
  }

  // `git diff --numstat -z` (staged with --cached): fills counts and binary flags.
  public static IReadOnlyList<GitFile> ApplyNumstat(IReadOnlyList<GitFile> files, string numstat)
  {
    var counts = new Dictionary<string, (int? Ins, int? Del, bool Binary)>(StringComparer.Ordinal);
    var fields = numstat.Split('\0');
    for (var i = 0; i < fields.Length; i++)
    {
      var parts = fields[i].Split('\t');
      if (parts.Length < 3) continue;
      var path = parts[2];
      if (path.Length == 0 && i + 2 < fields.Length) { i++; path = fields[++i]; } // rename: \0orig\0new
      var binary = parts[0] == "-" && parts[1] == "-";
      counts[path] = (binary ? null : int.TryParse(parts[0], out var a) ? a : null, binary ? null : int.TryParse(parts[1], out var d) ? d : null, binary);
    }
    return files.Select(f => counts.TryGetValue(f.Path, out var c) ? f with { Insertions = c.Ins, Deletions = c.Del, Binary = c.Binary } : f).ToArray();
  }

  public const string LogFormat = "%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1e";
  public static IReadOnlyList<GitCommitInfo> ParseLog(string text) =>
    text.Split('\x1e', StringSplitOptions.RemoveEmptyEntries).Select(r => r.Trim('\n', '\r').Split('\x1f')).Where(p => p.Length == 5)
      .Select(p => new GitCommitInfo(p[0], p[1], p[2], p[3], p[4])).ToArray();

  public const string BranchFormat = "%(refname)%1f%(HEAD)%1f%(upstream:short)";
  public static IReadOnlyList<GitBranchRef> ParseBranches(string text) =>
    text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(r => r.TrimEnd('\r').Split('\x1f')).Where(p => p.Length == 3 && !p[0].EndsWith("/HEAD", StringComparison.Ordinal))
      .Select(p => p[0].StartsWith("refs/remotes/", StringComparison.Ordinal) ? new GitBranchRef(p[0]["refs/remotes/".Length..], false, true, null)
        : new GitBranchRef(p[0].StartsWith("refs/heads/", StringComparison.Ordinal) ? p[0]["refs/heads/".Length..] : p[0], p[1] == "*", false, p[2].Length == 0 ? null : p[2])).ToArray();

  // One plain sentence for each way a git command fails; the raw line is kept as detail.
  public static string Explain(string verb, CodeProcessResult result)
  {
    if (result.Missing) return MissingMessage;
    if (result.TimedOut) return $"git {verb} took too long and was stopped. Check your connection and try again.";
    var error = (result.Error + "\n" + result.Output).Trim();
    bool Has(string text) => error.Contains(text, StringComparison.OrdinalIgnoreCase);
    if (Has("Authentication failed") || Has("could not read Username") || Has("could not read Password") || Has("terminal prompts disabled") || Has("Permission denied (publickey)"))
      return $"git {verb} could not sign in to the remote. Sign in once with Git Credential Manager (or set up your SSH key) and try again — Terminal Deck never stores your password.";
    if (Has("Could not resolve host") || Has("unable to access") || Has("Connection timed out") || Has("Could not read from remote"))
      return $"git {verb} could not reach the remote. Check your connection and the remote address, then try again.";
    if (Has("non-fast-forward") || Has("[rejected]") || Has("fetch first"))
      return "The remote has commits you don't have yet. Pull first, then push again.";
    if (Has("Not possible to fast-forward") || Has("have diverged") || Has("divergent branches"))
      return "Your branch and the remote have both changed. Merge or rebase them in a terminal, then try again.";
    if (Has("no upstream") || Has("has no upstream branch") || Has("There is no tracking information"))
      return "This branch is not linked to a remote branch yet. Push it once to link it.";
    if (Has("No configured push destination") || Has("does not appear to be a git repository") || Has("No remote repository specified"))
      return "This repository has no remote to talk to. Add one (for example with git remote add origin <address>) and try again.";
    if (Has("would be overwritten") || Has("Please commit your changes or stash them"))
      return $"Your uncommitted changes would be overwritten by git {verb}. Commit them or set them aside first.";
    if (Has("CONFLICT") || Has("Merge conflict")) return "git found conflicts. Resolve the files marked Conflict, stage them and commit.";
    if (Has("nothing to commit") || Has("no changes added to commit")) return "Nothing is staged. Stage the changes you want first.";
    if (Has("Please tell me who you are") || Has("user.email")) return "git needs your name and email before it can commit. Run git config --global user.name and user.email once in a terminal.";
    if (Has("already exists")) return "A branch with that name already exists.";
    if (Has("is not a valid branch name") || Has("not a valid branch name")) return "That is not a valid branch name.";
    if (Has("not a git repository")) return "This folder is not a git repository.";
    var first = error.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? "";
    if (first.StartsWith("fatal: ", StringComparison.Ordinal) || first.StartsWith("error: ", StringComparison.Ordinal)) first = first[(first.IndexOf(' ') + 1)..];
    return first.Length == 0 ? $"git {verb} did not finish." : $"git {verb} did not finish: {first}";
  }
}
