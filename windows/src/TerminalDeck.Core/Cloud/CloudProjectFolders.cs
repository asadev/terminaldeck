using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Project folders on this PC (the Mac's BackendProjectFolders.swift, owner 14 Nov: "sign in once and everything
// follows"). A project that arrives from the Cloud and has no folder here gets one BY ITSELF at
// `%USERPROFILE%\Terminal Deck\Projects\<project name>`, with no question and no click. Code is never fetched: the folder
// holds only what the Cloud carries ("Code not on this PC yet") until the person gets the code.
//
// The rules, all on this PC only (the folder path never travels):
// - A folder is made ONCE per project (this PC's ledger `cloud\project-folders.json`, never sent). A folder he later
//   moves or deletes is not made again.
// - The name is the project's name made safe for a folder; a place already taken (his folder or file, or another
//   project's folder) is never written into: the next plain name is used ("Deck 2"). Made create-new-only.
// - Only ever made, never emptied, moved or deleted, and only inside the Terminal Deck folder.
// - A disk-wide problem (full, read-only, no permission) stops every project for 5 minutes; a problem with one name only
//   falls back to "Project", "Project 2"; anything else waits for that project only.

public sealed class CloudProjectFolders
{
  public const string BaseName = "Terminal Deck", ProjectsName = "Projects";
  public const int MaximumNameBytes = 200, MaximumTries = 99;
  public const long RetryMilliseconds = 300_000;
  /// What the Cloud puts into a project's folder (instruction files, the AI tools' own folders) plus Explorer's own
  /// files: a folder holding only these has no code yet.
  public static readonly IReadOnlySet<string> CloudOnlyNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
  {
    "CLAUDE.md", "AGENTS.md", "GEMINI.md", "CLAUDE.local.md", ".claude", ".agents", ".codex", ".gemini", ".mcp.json", ".DS_Store", "desktop.ini", "Thumbs.db"
  };
  /// The app's one copy, for the project page's "Code not on this PC yet" line.
  public static CloudProjectFolders? Installed { get; set; }

  private sealed class Made { public string Path { get; set; } = ""; public bool Attached { get; set; } public bool? ByApp { get; set; } }
  private sealed class Saved { public Dictionary<string, Made> Made { get; set; } = []; }
  private readonly string file, profile;
  private readonly IReadOnlyList<string> protectedFolders;
  private readonly Func<long> now;
  private readonly object gate = new();
  private Saved saved;
  private long retryAt;
  private readonly Dictionary<string, long> skipUntil = new(StringComparer.Ordinal);
  /// The one calm line while a folder could not be made, else null.
  public string? Problem { get; private set; }

  /// `file`: this PC's ledger. `profile`: the user folder (`%USERPROFILE%`; a scratch folder in tests). `protectedFolders`:
  /// the app's own data folder (no project may point into it).
  public CloudProjectFolders(string file, string profile, IEnumerable<string>? protectedFolders = null, Func<long>? now = null)
  {
    this.file = file; this.profile = profile; this.protectedFolders = (protectedFolders ?? []).ToArray();
    this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    try { saved = File.Exists(file) ? JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(file)) ?? new Saved() : new Saved(); }
    catch (JsonException) { saved = new Saved(); }
  }
  public string ProjectsFolder => Path.Combine(profile, BaseName, ProjectsName);

  // ---- names ----

  private static readonly char[] Refused = ['/', '\\', ':', '?', '*', '"', '<', '>', '|'];
  /// The project's name as a folder name: none of `/ \ : ? * " < > |`, no control character, no leading dot, no
  /// trailing dot or space, trimmed, at most 200 UTF-8 bytes, never a reserved Windows name. Nothing left is "Project".
  public static string SafeName(string name)
  {
    var built = new StringBuilder();
    foreach (var c in name)
    {
      if (Refused.Contains(c)) { built.Append('-'); continue; }
      built.Append(char.IsControl(c) || c is '\u2028' or '\u2029' ? ' ' : c);
    }
    var result = built.ToString().Trim();
    while (result.StartsWith('.')) result = result[1..].Trim();
    while (Encoding.UTF8.GetByteCount(result) > MaximumNameBytes)
    {
      result = result[..^1];
      if (result.Length > 0 && char.IsHighSurrogate(result[^1])) result = result[..^1];
    }
    result = result.Trim();
    while (result.EndsWith('.') || result.EndsWith(' ')) result = result[..^1];
    if (result.Length == 0) return "Project";
    var stem = result.Split('.')[0].TrimEnd().ToUpperInvariant();
    if (stem is "CON" or "PRN" or "AUX" or "NUL" || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal))
      && stem[3] is >= '0' and <= '9' or '¹' or '²' or '³') result = result + " project";
    return result;
  }
  /// The plain names tried in order: "Deck", "Deck 2", "Deck 3"… Never an id or a code.
  public static IReadOnlyList<string> Candidates(string name)
  {
    var safe = SafeName(name);
    return [safe, .. Enumerable.Range(2, MaximumTries - 1).Select(n => safe + " " + n)];
  }

  // ---- which folders may be used ----

  private static string Full(string path) => System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path));
  /// The folder with every link resolved (a link named "Work" that points into AppData is judged as AppData).
  public static string Resolved(string path)
  {
    var full = Full(path);
    var parts = new List<string>();
    for (var d = new DirectoryInfo(full); d is not null; d = d.Parent)
    {
      if (d.Exists && d.LinkTarget is not null && d.ResolveLinkTarget(true) is { } target)
        return Full(System.IO.Path.Combine(new[] { Resolved(target.FullName) }.Concat(Enumerable.Reverse(parts)).ToArray()));
      if (d.Parent is null) { parts.Add(d.FullName); break; }
      parts.Add(d.Name);
    }
    parts.Reverse();
    return Full(System.IO.Path.Combine(parts.ToArray()));
  }
  private static bool Inside(string path, string folder) =>
    string.Equals(path, folder, StringComparison.OrdinalIgnoreCase) || path.StartsWith(folder.TrimEnd('\\', '/') + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
  private static readonly string[] SystemFolders =
  [
    Environment.GetFolderPath(Environment.SpecialFolder.Windows), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
    Environment.GetFolderPath(Environment.SpecialFolder.System)
  ];
  public const string Mine = "Choose a folder of your own: this one belongs to Windows, the app or your settings.";
  /// Why this folder may not become a project's folder, in one plain line; null when it may. Drive roots, Windows,
  /// Program Files and other system places, the user folder itself and every folder above it, AppData and hidden folders
  /// in the user folder, the app's own data folder, and another project's folder are refused.
  public static string? Refusal(string folder, string profile, IEnumerable<string>? protectedFolders = null, IEnumerable<string>? otherProjects = null)
  {
    var path = Resolved(folder);
    if (System.IO.Path.GetPathRoot(path) is { } root && string.Equals(Full(root), path, StringComparison.OrdinalIgnoreCase)) return Mine;
    foreach (var system in SystemFolders.Where(s => s.Length > 0)) if (Inside(path, Full(system))) return Mine;
    if (System.IO.Path.GetPathRoot(path) is { } drive)
      foreach (var name in new[] { "$Recycle.Bin", "System Volume Information", "Recovery" }) if (Inside(path, Full(System.IO.Path.Combine(drive, name)))) return Mine;
    foreach (var home in new[] { profile }.Where(h => h.Length > 0).Select(Resolved))
    {
      if (Inside(home, path)) return "Choose a folder inside your user folder, not the user folder itself.";
      if (!Inside(path, home)) continue;
      var first = path[(home.TrimEnd('\\', '/').Length + 1)..].Split('\\', '/')[0];
      if (first.StartsWith('.') || first.Equals("AppData", StringComparison.OrdinalIgnoreCase)) return Mine;
    }
    foreach (var guarded in (protectedFolders ?? []).Where(p => p.Length > 0)) if (Inside(path, Resolved(guarded))) return Mine;
    foreach (var other in (otherProjects ?? []).Where(p => p.Length > 0))
      if (string.Equals(Resolved(other), path, StringComparison.OrdinalIgnoreCase)) return "This folder is already another project's folder. Choose another one.";
    return null;
  }

  // ---- making folders ----

  public sealed class DiskProblem(string line) : Exception(line);
  private void Write(Saved next)
  {
    new CloudFileSlot(file).Write(JsonSerializer.SerializeToUtf8Bytes(next));
    saved = next;
  }
  private static Saved Copy(Saved s) => new() { Made = s.Made.ToDictionary(m => m.Key, m => new Made { Path = m.Value.Path, Attached = m.Value.Attached, ByApp = m.Value.ByApp }) };
  /// True when the app already made (or was given) a folder for this project once: it is never made again.
  public bool MadeBefore(string projectId) { lock (gate) return saved.Made.ContainsKey(projectId); }
  /// The folder for a project that arrived with no folder here: made now (create-new-only), or the one made for it on an
  /// earlier try that did not finish. Null: wait and try again later (every name taken, or this project's last try failed
  /// moments ago); `Problem` says why. Throws DiskProblem when the disk or the place refuses (every project waits).
  public string? FolderFor(string projectId, string name, IEnumerable<string> usedFolders)
  {
    lock (gate)
    {
      var time = now();
      if (time < retryAt) throw new DiskProblem(Problem ?? "Project folders could not be made on this PC. Tried again in a few minutes.");
      if (skipUntil.TryGetValue(projectId, out var until) && time < until) return null;
      if (saved.Made.TryGetValue(projectId, out var earlier))
        return !earlier.Attached && Directory.Exists(earlier.Path) ? earlier.Path : null;
      var used = usedFolders.Select(Full).ToHashSet(StringComparer.OrdinalIgnoreCase);
      var parent = ProjectsFolder;
      try { Directory.CreateDirectory(parent); }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw Fail(error, name); }
      if (Refusal(parent, profile, protectedFolders) is { } refused) { Problem = refused; retryAt = time + RetryMilliseconds; throw new DiskProblem(refused); }
      var lists = new List<IReadOnlyList<string>> { Candidates(name) };
      for (var index = 0; index < lists.Count; index++)
      {
        foreach (var candidate in lists[index])
        {
          var path = Full(Path.Combine(parent, candidate));
          if (used.Contains(path) || saved.Made.Values.Any(m => string.Equals(m.Path, path, StringComparison.OrdinalIgnoreCase))) continue;
          if (Directory.Exists(path) || File.Exists(path)) continue;
          // Create-new-only: made under a temporary name, then moved into place. The move fails when anything already
          // sits there (a folder, a file or a link of his), so his things are never taken over.
          var temporary = Path.Combine(parent, ".td-new-" + Guid.NewGuid().ToString("N"));
          try { Directory.CreateDirectory(temporary); }
          catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw Fail(error, name); }
          try { Directory.Move(temporary, path); }
          catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
          {
            try { Directory.Delete(temporary); } catch (Exception ignored) when (ignored is IOException or UnauthorizedAccessException) { }
            if (Directory.Exists(path) || File.Exists(path)) continue;
            if (error is PathTooLongException or ArgumentException or NotSupportedException || error is IOException { HResult: unchecked((int)0x8007007B) })
            {
              // The disk refuses this NAME: the plain fallback "Project", "Project 2" … (once).
              if (lists.Count == 1 && SafeName(name) != "Project") lists.Add(Candidates("Project"));
              break;
            }
            if (error is UnauthorizedAccessException || error is IOException { HResult: unchecked((int)0x80070070) or unchecked((int)0x80070027) or unchecked((int)0x80070013) })
              throw Fail(error, name);
            skipUntil[projectId] = time + RetryMilliseconds;
            Problem = "The folder for " + name + " could not be made on this PC (the folder could not be made). Tried again in a few minutes.";
            return null;
          }
          var next = Copy(saved);
          next.Made[projectId] = new Made { Path = path, Attached = false, ByApp = true };
          try { Write(next); }
          catch (Exception error) when (error is IOException or UnauthorizedAccessException) { try { Directory.Delete(path); } catch (Exception ignored) when (ignored is IOException or UnauthorizedAccessException) { } throw Fail(error, name); }
          Problem = null;
          return path;
        }
      }
      skipUntil[projectId] = time + RetryMilliseconds;
      Problem = "The folder for " + name + " could not be made on this PC (every name for it is taken). Tried again in a few minutes.";
      return null;
    }
  }
  private DiskProblem Fail(Exception error, string name)
  {
    retryAt = now() + RetryMilliseconds;
    var why = error is UnauthorizedAccessException || error.HResult == unchecked((int)0x80070013) ? "this PC does not allow writing there"
      : error.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027) ? "the disk is full" : "the folder could not be made";
    Problem = "The folder for " + name + " could not be made on this PC (" + why + "). Tried again in a few minutes.";
    return new DiskProblem(Problem);
  }
  /// The project now points at the folder made for it.
  public void Attached(string projectId)
  {
    lock (gate)
    {
      if (!saved.Made.TryGetValue(projectId, out var made) || made.Attached) return;
      var next = Copy(saved); next.Made[projectId].Attached = true;
      Write(next);
    }
  }
  /// True when the app made this folder for a project that came from the Cloud.
  public bool MadeByApp(string path)
  {
    lock (gate) return saved.Made.Values.Any(m => m.ByApp != false && m.Path.Length > 0 && string.Equals(Full(m.Path), Full(path), StringComparison.OrdinalIgnoreCase));
  }
  /// The folder still holds only what the Cloud puts there: the project's code is not on this PC yet.
  public static bool HoldsOnlyCloudFiles(string path)
  {
    try { return Directory.Exists(path) && Directory.EnumerateFileSystemEntries(path).All(e => CloudOnlyNames.Contains(Path.GetFileName(e))); }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }
  /// "Code not on this PC yet": a folder made by sync that holds only Cloud files. Code is never fetched by sync.
  public bool WaitingForCode(string? folder) => folder is not null && MadeByApp(folder) && HoldsOnlyCloudFiles(folder);
}
