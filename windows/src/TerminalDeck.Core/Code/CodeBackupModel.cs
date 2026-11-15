using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TerminalDeck.Core.Code;

// The Code page's backup to GitHub (port of the Mac's BackendCodeBackupModel/Ledger.swift, L5 slices 1 and 2, owner 14 Nov:
// "a place where we can see when last update happened to this specific project and code and is it completely updated or
// not"). One project as the page and code.projects show it: names, dates and plain words only. Never a token, an id on
// screen or a raw path (a folder is its name alone).
//
// A project with several code folders keeps each one in Parts; the project's own fields are then its WORST folder's, so
// "Backed up" shows only when every folder is.

public enum CodeBackupVisibility { NotChecked, Private, Public }
public enum CodeBackupState
{
  CommitsNotOnGitHub, FilesChanged, SetAside, NoHome, CouldNotCheck, SecretsInCommits, BackedUp, NoFolder,
  /// The app made the project's folder for a project that came from the Cloud and its code has not been fetched here yet.
  CodeNotHere,
  /// He set this project's backup to Off.
  BackupOff
}
/// How each project's code is backed up (owner, 13-14 Nov: "the code is the person's choice per project").
public enum CodeBackupMode { Automatic, Manual, Off }
public enum CodeBackupHeldReason { TooLarge, LooksSecret }
public sealed record CodeBackupCommit(string Subject, long At);
/// A file that is NOT on GitHub and cannot go there as it is.
public sealed record CodeBackupHeld(string Name, CodeBackupHeldReason Reason);

public static class CodeBackupWordsOf
{
  public static string Raw(CodeBackupState state) => state switch
  {
    CodeBackupState.CommitsNotOnGitHub => "commits not on GitHub", CodeBackupState.FilesChanged => "files changed",
    CodeBackupState.SetAside => "set-aside changes not on GitHub", CodeBackupState.NoHome => "no GitHub home yet",
    CodeBackupState.CouldNotCheck => "could not check", CodeBackupState.SecretsInCommits => "secret files in your commits",
    CodeBackupState.BackedUp => "backed up", CodeBackupState.NoFolder => "no code folder on this PC",
    CodeBackupState.CodeNotHere => "code not on this PC yet", _ => "backup off"
  };
  public static string Raw(CodeBackupVisibility visibility) => visibility switch { CodeBackupVisibility.Private => "private", CodeBackupVisibility.Public => "public", _ => "not checked" };
  public static string Raw(CodeBackupMode mode) => mode switch { CodeBackupMode.Automatic => "automatic", CodeBackupMode.Off => "off", _ => "manual" };
  public static string Word(CodeBackupMode mode) => mode switch { CodeBackupMode.Automatic => "Automatic", CodeBackupMode.Off => "Off", _ => "Manual" };
  public static CodeBackupMode? Mode(string? raw) => raw switch { "automatic" => CodeBackupMode.Automatic, "manual" => CodeBackupMode.Manual, "off" => CodeBackupMode.Off, _ => null };
}

public sealed class CodeBackupProject
{
  public CodeBackupProject(string id, string name) { Id = id; Name = name; }
  /// The row's identity only, never shown or returned to an AI. A part's id is its folder's name.
  public string Id { get; set; }
  public string Name { get; set; }
  /// The code folder's own name (its last part), never the path.
  public string? FolderName { get; set; }
  public bool HasFolder { get; set; }
  /// The folder is one the app made for a project from the Cloud and holds only what the Cloud put there: no code yet.
  public bool WaitingForCode { get; set; }
  public bool IsRepository { get; set; }
  /// "owner/name" when the code's home is on GitHub.
  public string? Home { get; set; }
  /// The remote's host when the code goes somewhere other than GitHub.
  public string? OtherHost { get; set; }
  public CodeBackupVisibility Visibility { get; set; } = CodeBackupVisibility.NotChecked;
  /// The branch he is on; null when a past version is checked out or there is no repository.
  public string? Branch { get; set; }
  /// The newest commit's time (ms).
  public long? LastCommitAt { get; set; }
  /// The newest commit of his that is on the home remote (ms): "last backed up".
  public long? LastBackedUpAt { get; set; }
  public int ChangedCount { get; set; }
  public List<string> ChangedFiles { get; set; } = [];
  public int CommitCount { get; set; }
  public List<CodeBackupCommit> Commits { get; set; } = [];
  /// Work he set aside (git stash): it lives only on this PC.
  public int SetAsideCount { get; set; }
  public List<CodeBackupHeld> Held { get; set; } = [];
  /// Secret files that ARE in his last commit.
  public List<string> SecretsInCommits { get; set; } = [];
  /// Why it could not be checked, in plain words.
  public string? Problem { get; set; }
  public List<CodeBackupProject> Parts { get; set; } = [];
  /// The changed files are in the last backup of uncommitted work (taken at this time, ms).
  public long? ChangesCoveredAt { get; set; }
  public bool SetAsideCovered { get; set; }
  /// His commits that are safe in the private backup references but NOT on his real GitHub branches.
  public int PrivateCommitCount { get; set; }
  public List<string> PrivateBranches { get; set; } = [];
  public CodeBackupMode Mode { get; set; } = CodeBackupMode.Manual;
  /// For "Code not on this PC yet", the GitHub home "Get the code" would use.
  public string? GetFrom { get; set; }
  /// A "Get the code" started here and has not finished.
  public bool Getting { get; set; }
  /// The last action's one line.
  public string? Note { get; set; }
  /// The home is on an organisation's (or another person's) account: Back up now only, never Automatic.
  public string? Organisation { get; set; }
  /// Terminal Deck made this home.
  public bool MadeHome { get; set; }
  /// When THIS PC last sent a backup of the project (ms) and this PC's name.
  public long? SentAt { get; set; }
  public string? SentFrom { get; set; }
  /// The GitHub page of the project's home.
  public string? HomeLink { get; set; }

  public const int ListLimit = 200;

  public CodeBackupProject Clone()
  {
    var copy = (CodeBackupProject)MemberwiseClone();
    copy.ChangedFiles = [.. ChangedFiles]; copy.Commits = [.. Commits]; copy.Held = [.. Held]; copy.SecretsInCommits = [.. SecretsInCommits];
    copy.PrivateBranches = [.. PrivateBranches]; copy.Parts = Parts.Select(p => p.Clone()).ToList();
    return copy;
  }

  public bool HasRemote => Home is not null || OtherHost is not null;
  /// The backup choices the row offers: an organisation's home has no Automatic.
  public IReadOnlyList<CodeBackupMode> ModeChoices => Organisation is null ? [CodeBackupMode.Automatic, CodeBackupMode.Manual, CodeBackupMode.Off] : [CodeBackupMode.Manual, CodeBackupMode.Off];

  public CodeBackupState State
  {
    get
    {
      if (Problem is not null) return CodeBackupState.CouldNotCheck;
      if (!HasFolder) return CodeBackupState.NoFolder;
      if (Getting || (!IsRepository && WaitingForCode)) return CodeBackupState.CodeNotHere;
      if (Mode == CodeBackupMode.Off) return CodeBackupState.BackupOff;
      if (!IsRepository || !HasRemote) return CodeBackupState.NoHome;
      if (CommitCount > 0) return CodeBackupState.CommitsNotOnGitHub;
      if (ChangedCount > 0 && ChangesCoveredAt is null) return CodeBackupState.FilesChanged;
      if (SetAsideCount > 0 && !SetAsideCovered) return CodeBackupState.SetAside;
      if (SecretsInCommits.Count > 0) return CodeBackupState.SecretsInCommits;
      return CodeBackupState.BackedUp;
    }
  }

  /// Sorting: what needs him first.
  public int Rank => State switch
  {
    CodeBackupState.CommitsNotOnGitHub => 0, CodeBackupState.FilesChanged => 1, CodeBackupState.SetAside => 2, CodeBackupState.NoHome => 3,
    CodeBackupState.CouldNotCheck => 4, CodeBackupState.SecretsInCommits => 5, CodeBackupState.BackedUp => Held.Count == 0 ? 7 : 6,
    CodeBackupState.BackupOff => 7, CodeBackupState.CodeNotHere => 8, _ => 9
  };
  public bool NeedsAttention => Rank <= 6;

  /// Back up now shows only when something here is safe nowhere on GitHub yet (or there is no home yet) and backup is not
  /// Off. Commits already kept privately are "backed up": no button pushes his real branches for him.
  public bool OffersBackUp
  {
    get
    {
      if (Mode == CodeBackupMode.Off || !(OtherHost is null || Parts.Count > 1)) return false;
      return State is CodeBackupState.CommitsNotOnGitHub or CodeBackupState.FilesChanged or CodeBackupState.SetAside or CodeBackupState.NoHome;
    }
  }

  /// A project from its folders: one folder is the project; several keep their own rows and the project shows the worst of
  /// them (ties: the first), with the OLDEST last backup (null when any folder has none).
  public static CodeBackupProject Combine(string id, string name, IReadOnlyList<CodeBackupProject> parts)
  {
    if (parts.Count == 0) return new(id, name);
    var worst = parts[0];
    foreach (var part in parts) if (part.Rank < worst.Rank) worst = part;
    var row = worst.Clone();
    row.Id = id; row.Name = name;
    if (parts.Count <= 1) return row;
    var backed = parts.Select(p => p.BackedUpAt).ToArray();
    row.LastBackedUpAt = backed.Any(b => b is null) ? null : backed.Min();
    row.Parts = parts.Select(p => p.Clone()).ToList();
    return row;
  }

  /// The same project with private/public filled in from GitHub's answers ("owner/name" lowercased).
  public CodeBackupProject Filling(IReadOnlyDictionary<string, CodeBackupVisibility> found)
  {
    var row = Clone();
    row.Visibility = Home is not null && found.TryGetValue(Home.ToLowerInvariant(), out var v) ? v : CodeBackupVisibility.NotChecked;
    row.Parts = Parts.Select(p => p.Filling(found)).ToList();
    return row;
  }
  public IEnumerable<string> Homes => new[] { Home }.Concat(Parts.Select(p => p.Home)).OfType<string>();

  /// The newest moment his work here is known to be on GitHub.
  public long? BackedUpAt
  {
    get
    {
      var covered = ChangedCount > 0 ? ChangesCoveredAt : null;
      if (LastBackedUpAt is { } a && covered is { } b) return Math.Max(a, b);
      return LastBackedUpAt ?? covered;
    }
  }
}

/// Everything the page and the tool show, read in one pass.
public sealed class CodeBackupReport
{
  public CodeBackupReport(IEnumerable<CodeBackupProject> projects, bool? signedInToGitHub, long checkedAt)
  {
    Projects = projects.OrderBy(p => p.Rank).ThenBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    SignedInToGitHub = signedInToGitHub; CheckedAt = checkedAt;
  }
  public IReadOnlyList<CodeBackupProject> Projects { get; }
  /// null until GitHub has answered once.
  public bool? SignedInToGitHub { get; }
  public long CheckedAt { get; }
  /// No "Back up now" has finished on this PC yet, so every project is still Manual here.
  public bool AutomaticWaits { get; set; }
}

/// The exact words, shared by the page and the tool. A row is a name, one state and at most one control.
public static class CodeBackupWords
{
  public const string Title = "Code";
  public const string SignInLine = "GitHub is not connected";
  public const string SignInButton = "Connect GitHub";
  public const string Refresh = "Refresh";
  public const string NoProjects = "No projects yet";
  public const string ChangedTitle = "Changed since the last commit";
  public const string CommitsTitle = "Commits not on GitHub";
  public const string SetAsideTitle = "Set-aside changes";
  public const string HeldTitle = "Can't go to GitHub as they are";
  public const string SecretsInCommitsTitle = "Secret files in your commits";
  public const string NotOnBranch = "No branch";
  public const string AutomaticWaitsLine = "Automatic backup starts after your first Back up now on this PC.";
  public const string MadeHomeLine = "Backed up privately. GitHub's page for this repository looks empty; that is expected.";
  public const string NotFoundOnGitHub = "Not on GitHub yet: Back up now on the computer that has its code";
  public const string BackUpNow = "Back up now", GetTheCode = "Get the code";

  public static string? HomeLine(CodeBackupProject project)
  {
    if (project.Organisation is { } organisation && project.Home is { } home)
      return "Home: " + home + " (organisation): Back up now only; everyone in " + organisation + " can see backups";
    return project.MadeHome ? MadeHomeLine : null;
  }

  internal static string Plural(int count, string one, string many) => count.ToString(CultureInfo.InvariantCulture) + " " + (count == 1 ? one : many);

  /// The row's one line. With several folders the worst folder's line is shown, led by its name.
  public static string Summary(CodeBackupProject project, DateTimeOffset now, TimeZoneInfo? zone = null)
  {
    var line = Own(project, now, zone ?? TimeZoneInfo.Local);
    return project.Parts.Count > 1 && project.FolderName is { } folder ? folder + ": " + line : line;
  }

  private static string Own(CodeBackupProject project, DateTimeOffset now, TimeZoneInfo zone)
  {
    switch (project.State)
    {
      case CodeBackupState.CouldNotCheck: return "Could not check (" + (project.Problem ?? "unknown reason") + ")";
      case CodeBackupState.NoFolder: return "No code folder on this PC";
      case CodeBackupState.CodeNotHere: return project.Getting ? "Getting the code stopped · continues where it stopped" : "Code not on this PC yet";
      case CodeBackupState.NoHome: return "Not on GitHub yet";
    }
    var parts = new List<string>();
    if (project.CommitCount > 0) parts.Add(Plural(project.CommitCount, "commit", "commits") + (project.Home is not null ? " not on GitHub" : " not pushed"));
    if (project.ChangedCount > 0 && project.ChangesCoveredAt is null)
    {
      var files = Plural(project.ChangedCount, "file", "files");
      parts.Add(project.LastCommitAt is { } at ? files + " changed since " + Short(at, now, zone) : files + " not committed yet");
    }
    if (project.SetAsideCount > 0 && !project.SetAsideCovered)
      parts.Add(Plural(project.SetAsideCount, "set-aside change", "set-aside changes") + (project.Home is not null ? " not on GitHub" : " not pushed"));
    var committed = project.SecretsInCommits.Count;
    if (committed > 0) parts.Add(committed == 1 ? "1 secret file is in your commits" : committed + " secret files are in your commits");
    if (project.State == CodeBackupState.BackupOff) parts.Insert(0, "Backup off");
    else if (parts.Count == 0) parts.Add(project.IsRepository && project.HasRemote ? "Backed up" : "Not on GitHub yet");
    if (project.PrivateCommitCount > 0)
    {
      var target = project.PrivateBranches.Count == 1 ? project.PrivateBranches[0] : "your GitHub branches";
      parts.Add(Plural(project.PrivateCommitCount, "commit", "commits") + " not pushed to " + target + ": backed up privately");
    }
    var large = project.Held.Count(h => h.Reason == CodeBackupHeldReason.TooLarge);
    var secret = project.Held.Count - large;
    if (large > 0) parts.Add(Plural(large, "file", "files") + " too large");
    if (secret > 0) parts.Add(Plural(secret, "secret file", "secret files") + " not sent to GitHub");
    return string.Join(" · ", parts);
  }

  /// "Last backed up Today, 22:14" / "Last backed up 13 Nov, 22:14" / "Never backed up"; empty without code here.
  public static string LastBackedUp(CodeBackupProject project, DateTimeOffset now, TimeZoneInfo? zone = null)
  {
    zone ??= TimeZoneInfo.Local;
    if (!project.HasFolder || project.Problem is not null || !project.IsRepository || project.Getting) return "";
    if (project.SentAt is { } sent && project.SentFrom is { Length: > 0 } pc && sent >= (project.BackedUpAt ?? 0))
      return "Last backed up " + When(sent, now, zone) + " from " + pc;
    return project.BackedUpAt is { } at ? "Last backed up " + When(at, now, zone) : "Never backed up";
  }

  private static readonly string[] Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  private static DateTime Local(long ms, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(ms), zone).DateTime;
  private static string Time(DateTime d) => d.ToString("HH:mm", CultureInfo.InvariantCulture);
  private static string Day(DateTime d) => d.Day.ToString(CultureInfo.InvariantCulture) + " " + Months[d.Month - 1];

  /// "Today, 22:14", "Yesterday, 09:05", "13 Nov, 22:14", "3 Mar 2025".
  public static string When(long ms, DateTimeOffset now, TimeZoneInfo? zone = null)
  {
    zone ??= TimeZoneInfo.Local;
    var date = Local(ms, zone); var today = TimeZoneInfo.ConvertTime(now, zone).DateTime.Date;
    if (date.Date == today) return "Today, " + Time(date);
    if (date.Date == today.AddDays(-1)) return "Yesterday, " + Time(date);
    if (date.Year == today.Year) return Day(date) + ", " + Time(date);
    return Day(date) + " " + date.Year.ToString(CultureInfo.InvariantCulture);
  }

  /// "22:14" today, "13 Nov" earlier.
  public static string Short(long ms, DateTimeOffset now, TimeZoneInfo? zone = null)
  {
    zone ??= TimeZoneInfo.Local;
    var date = Local(ms, zone); var today = TimeZoneInfo.ConvertTime(now, zone).DateTime.Date;
    if (date.Date == today) return Time(date);
    return date.Year == today.Year ? Day(date) : Day(date) + " " + date.Year.ToString(CultureInfo.InvariantCulture);
  }

  public static string Reason(CodeBackupHeldReason reason) => reason == CodeBackupHeldReason.TooLarge ? "over 50 MB" : "secret file";
}

/// What one backup of uncommitted work covered: the working state it was taken from, the set-aside changes it carried,
/// when, and the files it left out on purpose.
public sealed class CodeBackupCoverage
{
  public sealed record LeftOutFile(string Name, string Reason);
  public string Fingerprint { get; set; } = "";
  public List<string> Stashes { get; set; } = [];
  public long At { get; set; }
  public List<LeftOutFile> LeftOut { get; set; } = [];
  /// His branches as last kept in the private backup references (branch -> commit).
  public Dictionary<string, string>? Heads { get; set; }

  /// The working state of a repository as `status` sees it, plus each listed file's size and modification time. Nothing
  /// is written; one look per listed file.
  public static string MakeFingerprint(string head, string status, string top)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    hash.AppendData(Encoding.UTF8.GetBytes(head + "\n"));
    hash.AppendData(Encoding.UTF8.GetBytes(status));
    foreach (var name in CodeBackupReader.StatusNames(status))
      hash.AppendData(Encoding.UTF8.GetBytes("\0" + name + "\0" + CodeBackupDisk.Stamp(Path.Combine(top, name))));
    return Convert.ToHexStringLower(hash.GetHashAndReset());
  }
}

/// A "Get the code" that started and has not finished: where the download waits beside the project's folder.
public sealed record CodeBackupGetting(string Home, string Folder, string Temporary, long StartedAt);

/// This PC's own record for the Code page's actions (`<dataRoot>\code-backup.json`): the mode chosen per project, each
/// project's GitHub home as this PC knows it, what the last backup of uncommitted work covered (per repository), "Get the
/// code" runs still open, and the files a "Get the code" kept because his own differed. Never sent anywhere.
public sealed class CodeBackupLedger
{
  public const string FileName = "code-backup.json";
  private sealed class Saved
  {
    public Dictionary<string, CodeBackupMode> Modes { get; set; } = [];
    public Dictionary<string, string> Homes { get; set; } = [];
    public Dictionary<string, CodeBackupCoverage> Covered { get; set; } = [];
    public Dictionary<string, CodeBackupGetting> Getting { get; set; } = [];
    public Dictionary<string, List<string>> Kept { get; set; } = [];
    public List<string> Made { get; set; } = [];
    public List<string> Loud { get; set; } = [];
    public bool FirstBackupDone { get; set; }
    public string? SpareId { get; set; }
    public Dictionary<string, long> Sent { get; set; } = [];
  }
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true, PropertyNameCaseInsensitive = true, Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };
  private readonly string? file;
  private readonly object gate = new();
  private Saved saved;

  /// `file` null keeps everything in memory (tests).
  public CodeBackupLedger(string? file)
  {
    this.file = file;
    try { saved = file is not null && File.Exists(file) ? JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(file), Json) ?? new() : new(); }
    catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { saved = new(); }
    saved.Modes ??= []; saved.Homes ??= []; saved.Covered ??= []; saved.Getting ??= []; saved.Kept ??= []; saved.Made ??= []; saved.Loud ??= []; saved.Sent ??= [];
  }

  private void Change(Action<Saved> edit)
  {
    byte[] bytes;
    lock (gate) { edit(saved); bytes = JsonSerializer.SerializeToUtf8Bytes(saved, Json); }
    if (file is null) return;
    try
    {
      Directory.CreateDirectory(Path.GetDirectoryName(file)!);
      var temporary = file + ".tmp";
      File.WriteAllBytes(temporary, bytes);
      File.Move(temporary, file, overwrite: true);
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
  }

  /// The folder this record lives in (null for an in-memory record).
  public string? Folder => file is null ? null : Path.GetDirectoryName(file);
  public CodeBackupMode? Mode(string projectId) { lock (gate) return saved.Modes.TryGetValue(projectId, out var m) ? m : null; }
  public void SetMode(string projectId, CodeBackupMode mode) => Change(s => s.Modes[projectId] = mode);
  public string? Home(string projectId) { lock (gate) return saved.Homes.GetValueOrDefault(projectId); }
  public void SetHome(string projectId, string home) => Change(s => s.Homes[projectId] = home);
  public CodeBackupCoverage? Coverage(string gitDir) { lock (gate) return saved.Covered.GetValueOrDefault(gitDir); }
  public void SetCoverage(string gitDir, CodeBackupCoverage coverage) => Change(s => s.Covered[gitDir] = coverage);
  public CodeBackupGetting? Getting(string projectId) { lock (gate) return saved.Getting.GetValueOrDefault(projectId); }
  public IReadOnlyDictionary<string, CodeBackupGetting> AllGetting { get { lock (gate) return new Dictionary<string, CodeBackupGetting>(saved.Getting); } }
  public void SetGetting(string projectId, CodeBackupGetting? value) => Change(s => { if (value is null) s.Getting.Remove(projectId); else s.Getting[projectId] = value; });
  /// Real branch and tag names only for a home Terminal Deck made that has never shown anything that reacts to a push.
  public bool UsesRealNames(string home) { var key = home.ToLowerInvariant(); lock (gate) return saved.Made.Contains(key) && !saved.Loud.Contains(key); }
  public bool IsMade(string home) { lock (gate) return saved.Made.Contains(home.ToLowerInvariant()); }
  public void MadeHome(string home) => Change(s => { if (!s.Made.Contains(home.ToLowerInvariant())) s.Made.Add(home.ToLowerInvariant()); });
  public void MarkLoud(string home) => Change(s => { if (!s.Loud.Contains(home.ToLowerInvariant())) s.Loud.Add(home.ToLowerInvariant()); });
  public bool FirstBackupDone { get { lock (gate) return saved.FirstBackupDone; } }
  public void SetFirstBackupDone() { if (!FirstBackupDone) Change(s => s.FirstBackupDone = true); }
  public long? SentAt(string projectId) { lock (gate) return saved.Sent.TryGetValue(projectId, out var at) ? at : null; }
  public void SetSent(string projectId, long at) => Change(s => s.Sent[projectId] = at);
  /// This PC's spare id (made once, kept): used only when the machine id cannot be read.
  public string SpareId()
  {
    lock (gate) if (saved.SpareId is { } kept) return kept;
    var made = Guid.NewGuid().ToString("N")[..8];
    Change(s => s.SpareId ??= made);
    lock (gate) return saved.SpareId ?? made;
  }
  public IReadOnlyList<string> Kept(string projectId) { lock (gate) return saved.Kept.TryGetValue(projectId, out var k) ? [.. k] : []; }
  public void SetKept(string projectId, IReadOnlyList<string> names) => Change(s => { if (names.Count == 0) s.Kept.Remove(projectId); else s.Kept[projectId] = [.. names]; });
}
