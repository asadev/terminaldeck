using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace TerminalDeck.Core.Code;

// Git for the Code page's backup (port of the Mac's BackendGitRunner + BackendCodeBackupGitWriter). Every command: no
// hooks, no automatic clean-up, no signing prompts, no pager, no file-system monitor, GIT_OPTIONAL_LOCKS=0, no credential
// window (GCM_INTERACTIVE=never, GIT_TERMINAL_PROMPT=0), Git never climbs into the home folder, and settings this caller
// passes (a separate staging-area file, the sign-in's GIT_CONFIG_*) go through the environment only.
public interface ICodeBackupGit
{
  Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default);
}

public sealed class CodeBackupGitRunner(string home, IReadOnlyDictionary<string, string?>? inherited = null, string executable = "git") : ICodeBackupGit
{
  public static readonly string[] Flags = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
    "-c", "core.untrackedCache=false", "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false", "-c", "push.gpgSign=false",
    "-c", "fetch.prune=false", "-c", "fetch.pruneTags=false", "-c", "fetch.recurseSubmodules=false",
    "-c", "push.recurseSubmodules=no", "-c", "push.followTags=false", "-c", "push.default=nothing",
    "-c", "submodule.recurse=false", "-c", "advice.detachedHead=false", "-c", "core.quotepath=off"];
  /// Variables that would point Git at another repository, index or settings than the command names.
  public static readonly string[] RepositoryVariables = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_CONFIG_PARAMETERS", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_EXTERNAL_DIFF", "GIT_SSH_COMMAND"];

  public async Task<CodeProcessResult> RunAsync(string cwd, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment, int timeoutMilliseconds, int maximumBytes, CancellationToken ct = default)
  {
    ct.ThrowIfCancellationRequested();
    if (!Directory.Exists(cwd)) return new(128, "", "fatal: cannot change to '" + Path.GetFileName(cwd) + "': No such directory");
    var start = new ProcessStartInfo(executable)
    {
      RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true,
      WorkingDirectory = cwd, StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
    };
    start.ArgumentList.Add("--no-pager");
    foreach (var flag in Flags) start.ArgumentList.Add(flag);
    foreach (var argument in arguments) start.ArgumentList.Add(argument);
    var env = start.Environment;
    foreach (var name in RepositoryVariables) env.Remove(name);
    foreach (var key in env.Keys.Where(k => k.StartsWith("GIT_CONFIG_KEY_", StringComparison.OrdinalIgnoreCase) || k.StartsWith("GIT_CONFIG_VALUE_", StringComparison.OrdinalIgnoreCase) || k.Equals("GIT_CONFIG_COUNT", StringComparison.OrdinalIgnoreCase)).ToArray()) env.Remove(key);
    foreach (var (name, value) in inherited ?? new Dictionary<string, string?>()) { if (value is null) env.Remove(name); else env[name] = value; }
    env["LC_ALL"] = "C"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"; env["GIT_PAGER"] = "cat"; env["PAGER"] = "cat";
    env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_CEILING_DIRECTORIES"] = home;
    foreach (var (name, value) in environment) env[name] = value;
    Process process;
    try { process = Process.Start(start) ?? throw new Win32Exception(); }
    catch (Win32Exception) { return new(127, "", "git is not installed", Missing: true); }
    using (process)
    {
      process.StandardInput.Close();
      var output = Read(process.StandardOutput, Math.Clamp(maximumBytes, 1, 32 * 1024 * 1024));
      var error = Read(process.StandardError, 1024 * 1024);
      using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
      limit.CancelAfter(Math.Clamp(timeoutMilliseconds, 1, 600_000));
      try { await process.WaitForExitAsync(limit.Token); }
      catch (OperationCanceledException)
      {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        ct.ThrowIfCancellationRequested();
        return new(-1, await output, await error, TimedOut: true);
      }
      return new(process.ExitCode, await output, await error);
    }
  }

  // Reads everything (so the child never blocks on a full pipe) but keeps at most `maximum` characters.
  private static async Task<string> Read(StreamReader reader, int maximum)
  {
    var kept = new StringBuilder(); var buffer = new char[16384];
    int read;
    while ((read = await reader.ReadAsync(buffer, CancellationToken.None)) > 0)
      if (kept.Length < maximum) kept.Append(buffer, 0, Math.Min(read, maximum - kept.Length));
    return kept.ToString();
  }

  /// Settings passed to Git through its environment (GIT_CONFIG_COUNT), never through arguments.
  public static Dictionary<string, string> Settings(IReadOnlyList<(string Key, string Value)> pairs, IReadOnlyDictionary<string, string>? extra = null)
  {
    var environment = new Dictionary<string, string>(extra ?? new Dictionary<string, string>());
    environment["GIT_CONFIG_COUNT"] = pairs.Count.ToString(System.Globalization.CultureInfo.InvariantCulture);
    for (var i = 0; i < pairs.Count; i++) { environment["GIT_CONFIG_KEY_" + i] = pairs[i].Key; environment["GIT_CONFIG_VALUE_" + i] = pairs[i].Value; }
    return environment;
  }
  public static Dictionary<string, string> Merge(IReadOnlyDictionary<string, string> first, IReadOnlyDictionary<string, string> second)
  {
    var all = new Dictionary<string, string>(first);
    foreach (var (k, v) in second) all[k] = v;
    return all;
  }
}

/// Blocking file-system work (is this a folder, the cache's stamps, file sizes) runs off the shared pool with its own time
/// limit, so a frozen network drive cannot stall the app. A folder that did not answer is remembered for five minutes.
public static class CodeBackupDisk
{
  public const double ForgetAfterSeconds = 300;
  private static readonly ConcurrentDictionary<string, DateTimeOffset> hung = new(StringComparer.OrdinalIgnoreCase);
  public static bool RecentlyHung(string path) => hung.TryGetValue(path, out var at) && (DateTimeOffset.UtcNow - at).TotalSeconds < ForgetAfterSeconds;
  public static void NoteHung(IEnumerable<string> paths) { foreach (var path in paths) hung[path] = DateTimeOffset.UtcNow; }
  internal static void ForgetAll() => hung.Clear();

  /// The work's answer, or (false, default) when it took longer than `seconds` (it is then left running on its own).
  public static async Task<(bool Done, T Value)> Run<T>(double seconds, Func<T> work)
  {
    var task = Task.Factory.StartNew(work, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    var winner = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(seconds)));
    if (winner != task) return (false, default!);
    try { return (true, await task); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return (false, default!); }
  }

  /// The paths that are folders, each checked on its own; null when any of them did not answer now or recently.
  public static async Task<List<string>?> Folders(IReadOnlyList<string> paths, double seconds, Func<string, bool> isDirectory)
  {
    if (paths.Any(RecentlyHung)) return null;
    var answers = await Task.WhenAll(paths.Select(async path => (path, answer: await Run(seconds, () => isDirectory(path)))));
    var silent = answers.Where(a => !a.answer.Done).Select(a => a.path).ToArray();
    if (silent.Length > 0) { NoteHung(silent); return null; }
    return answers.Where(a => a.answer.Value).Select(a => a.path).ToList();
  }

  /// A file's size and modification time ("-" when it is not there); links are not followed.
  public static string Stamp(string path)
  {
    try
    {
      FileSystemInfo info = File.Exists(path) ? new FileInfo(path) : new DirectoryInfo(path);
      if (!info.Exists) return "-";
      var size = info is FileInfo file ? file.Length : 0;
      return size.ToString(System.Globalization.CultureInfo.InvariantCulture) + "." + info.LastWriteTimeUtc.Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return "-"; }
  }
  /// A plain file (not a link) and its size; null otherwise.
  public static long? RegularSize(string path)
  {
    try
    {
      var info = new FileInfo(path);
      if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return null;
      return info.Length;
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
  }
  /// A real folder (a link to one is not followed).
  public static bool RealFolder(string path)
  {
    try { var info = new DirectoryInfo(path); return info.Exists && !info.Attributes.HasFlag(FileAttributes.ReparsePoint); }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }
  /// Removes a folder of the app's own (a download, a scratch area), read-only files included (Git's packs are read-only
  /// on Windows). Never used on a folder of his.
  public static void Delete(string folder)
  {
    try
    {
      if (!Directory.Exists(folder)) return;
      foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories))
        try { File.SetAttributes(file, FileAttributes.Normal); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
      Directory.Delete(folder, true);
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
  }
  /// Something is at this path (file, folder or link).
  public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path) || new FileInfo(path).LinkTarget is not null;
}

/// Which Git repository is a project folder's code (port of the Mac's BackendProjectCode, 14 Nov CODE-PARENT). A repository
/// is the folder's code when its top folder IS the project folder or lies INSIDE it. A repository whose top lies ABOVE the
/// folder is used only for a folder inside his own checkout, and only when its top is not the home folder (or above) nor
/// the Terminal Deck folder (or above), no folder the app made lies between, and that repository already TRACKS files
/// inside the folder. So a PC whose home folder is itself a repository never backs that repository up as a project's code.
public static class CodeBackupProjectCode
{
  public sealed record Bounds(IReadOnlyList<string> Homes, string? Base, Func<string, bool> MadeByApp)
  {
    /// This PC's: the user folder, the Terminal Deck folder, the installed project-folders ledger.
    public static Bounds Live()
    {
      var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      return new([profile], Path.Combine(profile, TerminalDeck.Core.Cloud.CloudProjectFolders.BaseName),
        folder => TerminalDeck.Core.Cloud.CloudProjectFolders.Installed?.MadeByApp(folder) == true);
    }
  }
  /// Runs one read-only Git command in `cwd` and answers what it printed, or null when Git could not run.
  public delegate Task<string?> Probe(string cwd, IReadOnlyList<string> arguments);

  private static StringComparison Compare => OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
  public static string Resolved(string path)
  {
    try { return Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)); } catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return path; }
  }
  /// `path` is `folder` or lies inside it.
  public static bool Inside(string path, string folder)
  {
    path = Resolved(path); folder = Resolved(folder);
    return string.Equals(path, folder, Compare) || path.StartsWith(folder.EndsWith(Path.DirectorySeparatorChar) ? folder : folder + Path.DirectorySeparatorChar, Compare);
  }

  public static bool Belongs(string top, string folder, Bounds bounds)
  {
    var t = Resolved(top); var place = Resolved(folder);
    if (Inside(t, place)) return true;
    if (!Inside(place, t)) return false;
    if (bounds.MadeByApp(folder)) return false;
    var step = place;
    while (!string.Equals(step, t, Compare) && step.Length > t.Length)
    {
      if (bounds.MadeByApp(step)) return false;
      step = Path.GetDirectoryName(step) ?? t;
    }
    foreach (var home in bounds.Homes) if (home.Length > 0 && Inside(home, t)) return false;
    if (bounds.Base is { Length: > 0 } b && Inside(b, t)) return false;
    return true;
  }

  public static async Task<bool> Owns(string top, string folder, Bounds bounds, Probe probe)
  {
    if (!Belongs(top, folder, bounds)) return false;
    var t = Resolved(top); var place = Resolved(folder);
    if (Inside(t, place)) return true;
    return await TracksInside(t, place, probe);
  }

  /// The app made this folder for a project from the Cloud and it still holds only what the Cloud puts there.
  public static bool WaitingForCode(string folder, Bounds bounds) =>
    (bounds.MadeByApp(folder) || bounds.MadeByApp(Resolved(folder))) && TerminalDeck.Core.Cloud.CloudProjectFolders.HoldsOnlyCloudFiles(folder);

  /// The nearest folder from `folder` upward (the folder itself first) that holds a `.git`.
  public static string? NearestTop(string folder)
  {
    var path = Resolved(folder);
    for (var i = 0; i < 128 && path.Length > 0; i++)
    {
      if (CodeBackupDisk.Exists(Path.Combine(path, ".git"))) return path;
      var parent = Path.GetDirectoryName(path);
      if (parent is null || parent == path) return null;
      path = parent;
    }
    return null;
  }

  private static readonly ConcurrentDictionary<string, (bool Answer, string Mark, DateTimeOffset At)> kept = new(StringComparer.OrdinalIgnoreCase);
  public static async Task<bool> TracksInside(string top, string folder, Probe probe)
  {
    var key = top + "\0" + folder; var mark = CodeBackupDisk.Stamp(Path.Combine(top, ".git", "index")); var now = DateTimeOffset.UtcNow;
    if (kept.TryGetValue(key, out var old) && old.Mark == mark && (now - old.At).TotalSeconds < 60) return old.Answer;
    var relative = Path.GetRelativePath(top, folder).Replace('\\', '/');
    var listed = await probe(top, ["ls-files", "-z", "--", ":(literal)" + relative]);
    var answer = !string.IsNullOrEmpty(listed);
    if (kept.Count > 500) kept.Clear();
    kept[key] = (answer, mark, now);
    return answer;
  }
  internal static void ForgetAnswers() => kept.Clear();
}
