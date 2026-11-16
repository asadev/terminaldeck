using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Code;

/// Scratch folders and a scratch Git for the Code backup tests: a temporary root, its own home folder and empty Git
/// settings (no system or global config of whoever runs the tests is read), local bare repositories standing in for
/// GitHub. Nothing ever reaches the network or a real GitHub account.
public sealed class CodeBackupScratch : IDisposable
{
  public string Root { get; } = Path.Combine(Path.GetTempPath(), "code-backup-" + Guid.NewGuid().ToString("N")[..12]);
  public string Home => Path.Combine(Root, "home");
  public CodeBackupScratch()
  {
    Directory.CreateDirectory(Home);
    File.WriteAllBytes(Path.Combine(Root, "gitconfig"), []);
  }
  public void Dispose() => CodeBackupDisk.Delete(Root);

  public Dictionary<string, string?> Environment => new()
  {
    ["HOME"] = Home, ["XDG_CONFIG_HOME"] = Home, ["GIT_CONFIG_NOSYSTEM"] = "1", ["GIT_CONFIG_GLOBAL"] = Path.Combine(Root, "gitconfig"),
    ["GCM_INTERACTIVE"] = "never", ["GIT_TERMINAL_PROMPT"] = "0"
  };
  public CodeBackupGitRunner Runner(string executable = "git") => new(Home, Environment, executable);

  public string Git(string cwd, params string[] args) => GitAt(cwd, null, args);
  public string GitAt(string cwd, long? seconds, params string[] args)
  {
    var start = new ProcessStartInfo("git") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = cwd,
      StandardOutputEncoding = new UTF8Encoding(false) };
    foreach (var a in new[] { "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always", "-c", "core.autocrlf=false" }) start.ArgumentList.Add(a);
    foreach (var a in args) start.ArgumentList.Add(a);
    foreach (var (k, v) in Environment) start.Environment[k] = v;
    foreach (var name in CodeBackupGitRunner.RepositoryVariables) start.Environment.Remove(name);
    if (seconds is { } at) { start.Environment["GIT_AUTHOR_DATE"] = "@" + at + " +0000"; start.Environment["GIT_COMMITTER_DATE"] = "@" + at + " +0000"; }
    using var process = Process.Start(start)!;
    var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
    process.WaitForExit();
    if (process.ExitCode != 0) throw new InvalidOperationException("git " + string.Join(' ', args) + ": " + error.Result);
    return output.Result;
  }
  public string GitTrim(string cwd, params string[] args) => Git(cwd, args).Trim();

  public void Write(string folder, string name, string text)
  {
    var file = Path.Combine(folder, name);
    Directory.CreateDirectory(Path.GetDirectoryName(file)!);
    File.WriteAllBytes(file, Encoding.UTF8.GetBytes(text));
  }
  public string? Read(string folder, string name) => File.Exists(Path.Combine(folder, name)) ? File.ReadAllText(Path.Combine(folder, name)) : null;
  public string Folder(string name) { var path = Path.Combine(Root, name); Directory.CreateDirectory(path); return path; }
  public string Repo(string name) { var repo = Folder(name); Git(repo, "init", "-q"); return repo; }
  public void Commit(string repo, string file, string message, long at)
  {
    Write(repo, file, message + "\n");
    Git(repo, "add", "-A"); GitAt(repo, at, "commit", "-q", "-m", message);
  }

  public Dictionary<string, string> Refs(string repo)
  {
    var refs = new Dictionary<string, string>();
    foreach (var line in Git(repo, "for-each-ref", "--format=%(refname) %(objectname)").Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      var parts = line.Trim().Split(' ');
      if (parts.Length == 2) refs[parts[0]] = parts[1];
    }
    return refs;
  }

  /// Every file under a folder, `.git` included: its bytes' hash (folders marked).
  public static Dictionary<string, string> Snapshot(string folder, params string[] skipping)
  {
    var result = new Dictionary<string, string>();
    foreach (var entry in Directory.EnumerateFileSystemEntries(folder, "*", SearchOption.AllDirectories))
    {
      var key = Path.GetRelativePath(folder, entry).Replace('\\', '/');
      if (skipping.Any(s => key.StartsWith(s, StringComparison.Ordinal))) continue;
      if (Directory.Exists(entry)) { result[key] = "dir"; continue; }
      var info = new FileInfo(entry);
      result[key] = info.Length > 1_000_000 ? info.Length + "@" + info.LastWriteTimeUtc.Ticks : Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(entry)));
    }
    return result;
  }

  /// His side of a repository that a backup must never change: his whole folder byte for byte, `.git` included, plus
  /// every reference and his stash as Git lists them.
  public Dictionary<string, string> HisSide(string repo)
  {
    var side = Snapshot(repo);
    foreach (var (name, value) in Refs(repo)) side["ref " + name] = value;
    try { side["stash"] = Git(repo, "stash", "list", "--format=%H"); } catch (InvalidOperationException) { side["stash"] = ""; }
    return side;
  }
}

/// Counts every Git command (and fails if the Code page's read ever asks Git to write).
public sealed class CountingGit(ICodeBackupGit inner) : ICodeBackupGit
{
  private int calls;
  public int Calls => Volatile.Read(ref calls);
  public Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default)
  {
    Interlocked.Increment(ref calls);
    return inner.RunAsync(cwd, arguments, environment, timeoutMilliseconds, maximumBytes, ct);
  }
}

/// Never answers in time.
public sealed class HangingGit : ICodeBackupGit
{
  public async Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default)
  {
    await Task.Delay(TimeSpan.FromSeconds(60), ct);
    throw new OperationCanceledException();
  }
}
