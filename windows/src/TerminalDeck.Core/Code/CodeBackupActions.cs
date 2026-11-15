using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Code;

/// One GitHub repository as the Code page's actions need it.
public sealed record CodeBackupRepo(string NameWithOwner, bool IsPrivate, bool CanPush, string? Description = null)
{
  public string Owner => NameWithOwner.Split('/')[0];
  public string Name => NameWithOwner.Split('/')[^1];
}
public abstract record CodeBackupCreated
{
  public sealed record Made(CodeBackupRepo Repo) : CodeBackupCreated;
  /// The name is already used on his account.
  public sealed record Taken : CodeBackupCreated;
  /// GitHub said no; the plain reason.
  public sealed record Refused(string Reason) : CodeBackupCreated;
}

/// The GitHub side of the actions. The live one uses the sign-in the app already has (the GitHub CLI's); tests use a
/// fake and never reach GitHub.
public interface ICodeBackupAccount
{
  /// His GitHub login; null when this PC is not connected to GitHub.
  Task<string?> Login();
  Task<IReadOnlyList<CodeBackupRepo>> Repositories();
  /// One repository ("owner/name"), null when it does not exist or the sign-in cannot see it.
  Task<CodeBackupRepo?> Repository(string home);
  /// Makes a NEW repository on his own account. Always private; never anything else.
  Task<CodeBackupCreated> Create(string name, string description);
  /// How Git reaches the home with his sign-in; null without a sign-in.
  Task<CodeBackupTransport?> Transport(string home);
  /// True only when GitHub POSITIVELY says nothing on this home reacts to a push. Any doubt is false.
  Task<bool> Quiet(string home);
}

/// The live account: the GitHub CLI's own sign-in (as the GitHub page uses it; a test or scratch copy gets its own gh
/// folder, never the person's). The token is read with `gh auth token` and only ever goes into Git's environment.
public sealed class CodeBackupGhAccount(ICodeProcessRunner runner, string host = "github.com") : ICodeBackupAccount
{
  private static readonly TimeSpan Limit = TimeSpan.FromSeconds(20);
  private (DateTimeOffset At, string? Login, IReadOnlyList<CodeBackupRepo> Repos)? cached;
  private readonly SemaphoreSlim gate = new(1, 1);

  public static CodeBackupGhAccount ForCopy(string dataRoot, bool realCopy) => realCopy ? new(new CodeProcessRunner()) :
    new(new CodeProcessRunner(new Dictionary<string, string?> { ["GH_CONFIG_DIR"] = Path.Combine(dataRoot, "github"), ["GH_TOKEN"] = null, ["GITHUB_TOKEN"] = null }));

  private async Task<CodeProcessResult> Gh(params string[] args) =>
    await runner.RunAsync("gh", args, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Limit, CancellationToken.None);

  private static CodeBackupRepo? Repo(JsonElement raw) =>
    raw.ValueKind == JsonValueKind.Object && raw.TryGetProperty("full_name", out var full) && full.GetString() is { } name
      ? new(name, raw.TryGetProperty("private", out var p) && p.ValueKind == JsonValueKind.True,
        raw.TryGetProperty("permissions", out var perms) && perms.ValueKind == JsonValueKind.Object && perms.TryGetProperty("push", out var push) && push.ValueKind == JsonValueKind.True,
        raw.TryGetProperty("description", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() : null)
      : null;

  // The sign-in's status, kept a minute (as the Mac's authenticator keeps it).
  private async Task<(string? Login, IReadOnlyList<CodeBackupRepo> Repos)> Status()
  {
    await gate.WaitAsync();
    try
    {
      if (cached is { } kept && (DateTimeOffset.UtcNow - kept.At).TotalSeconds < 60) return (kept.Login, kept.Repos);
      string? login = null; var repos = new List<CodeBackupRepo>();
      var user = await Gh("api", "--hostname", host, "user");
      if (user.Ok)
      {
        try
        {
          using var doc = JsonDocument.Parse(user.Output);
          login = doc.RootElement.TryGetProperty("login", out var l) && l.GetString() is { Length: > 0 } found ? found : null;
        }
        catch (JsonException) { }
      }
      if (login is not null)
      {
        var list = await Gh("api", "--hostname", host, "user/repos?per_page=100&sort=pushed");
        if (list.Ok)
          try { using var doc = JsonDocument.Parse(list.Output); foreach (var row in doc.RootElement.EnumerateArray()) if (Repo(row) is { } repo) repos.Add(repo); }
          catch (JsonException) { }
      }
      cached = (DateTimeOffset.UtcNow, login, repos);
      return (login, repos);
    }
    finally { gate.Release(); }
  }

  public async Task<string?> Login() => (await Status()).Login;
  public async Task<IReadOnlyList<CodeBackupRepo>> Repositories() => (await Status()).Repos;

  private async Task<string?> Token()
  {
    var outcome = await Gh("auth", "token", "--hostname", host);
    var found = outcome.Ok ? outcome.Output.Trim() : "";
    return found.Length is > 0 and <= 4096 && !found.Any(char.IsWhiteSpace) ? found : null;
  }

  public async Task<CodeBackupRepo?> Repository(string home)
  {
    var outcome = await Gh("api", "--hostname", host, "repos/" + home);
    if (!outcome.Ok) return null;
    try { using var doc = JsonDocument.Parse(outcome.Output); return Repo(doc.RootElement); } catch (JsonException) { return null; }
  }

  public async Task<CodeBackupCreated> Create(string name, string description)
  {
    if (await Login() is null) return new CodeBackupCreated.Refused("GitHub is not connected");
    // private: true is the only visibility this app ever asks for.
    var outcome = await Gh("api", "--hostname", host, "-X", "POST", "user/repos", "-f", "name=" + name, "-F", "private=true", "-f", "description=" + description, "-F", "auto_init=false");
    var all = outcome.Output + "\n" + outcome.Error;
    if (!outcome.Ok && all.Contains("already exists", StringComparison.OrdinalIgnoreCase)) return new CodeBackupCreated.Taken();
    if (outcome.Ok)
      try { using var doc = JsonDocument.Parse(outcome.Output); if (Repo(doc.RootElement) is { } made) { cached = null; return new CodeBackupCreated.Made(made with { CanPush = true }); } }
      catch (JsonException) { }
    if (all.Contains("HTTP 403", StringComparison.Ordinal) || all.Contains("HTTP 404", StringComparison.Ordinal)) return new CodeBackupCreated.Refused("GitHub did not allow this sign-in to make a repository");
    return new CodeBackupCreated.Refused(outcome.Missing ? "the GitHub CLI (gh) is not installed" : "GitHub did not answer");
  }

  public async Task<CodeBackupTransport?> Transport(string home) => await Token() is { } token ? CodeBackupTransport.Https(host, home, token) : null;
  /// Only asked on the real-names path, which is unreachable in this release (CodeBackupPlan.RealNamesAllowed is false).
  public Task<bool> Quiet(string home) => Task.FromResult(false);
}

// The Code page's actions (port of the Mac's BackendCodeBackupActions, owner 13-14 Nov): Back up now, a private home on
// GitHub for a project that has none, Get the code, and Automatic / Manual / Off per project.
// Rules every action keeps:
// - WHOSE ACCOUNT: only the GitHub sign-in the app already has. A home on another account or an organisation is written to
//   only when it is ALREADY the project's home AND GitHub says this sign-in may push there. New homes on his own account.
// - PRIVATE: a new home is always private; an existing home's visibility is never changed; a public home gets nothing.
// - NO SIDE EFFECTS ON GITHUB: only private references (refs/terminal-deck-backup/…), never a branch or a tag.
// - WHICH REPOSITORY: only one that CodeBackupProjectCode.Owns for one of the project's folders, checked again right
//   before any change, never one whose top is the home folder or the Terminal Deck folder (or above).
// - ADDS ONLY: see CodeBackupPlan and CodeBackupSend.
public sealed partial class CodeBackupActions
{
  public sealed record Outcome(bool Ok, string Line);
  /// What an action would do, for the approval line.
  public sealed record Target(string ProjectId, string Name, string? Address, bool NewHome, string? Organisation, string? Folder);

  public const double LookSeconds = 300, SettleSeconds = 300, GapSeconds = 900;
  public const string AutomaticRule = "Automatic backs up when a project's work has not changed for 5 minutes, at most every 15 minutes, on a normal network (not a metered connection), and never while Git is busy in it. Cost: one quick read of each Automatic project every 5 minutes; the network only when there is something new.";
  public const string LfsLine = "Large files (Git LFS) are not included";

  public CodeBackupProjects Projects { get; }
  public CodeBackupLedger Ledger { get; }
  private readonly ICodeBackupAccount account;
  private readonly ICodeBackupGit git;
  private readonly string host, computer, computerTitle, workArea;
  private readonly Func<CodeBackupProjectCode.Bounds> bounds;
  private readonly Func<bool> network;
  private readonly Func<DateTimeOffset> now;
  private readonly object gate = new();
  private readonly HashSet<string> busy = [];
  private readonly Dictionary<string, string> notes = [];
  private readonly Dictionary<string, (string Mark, DateTimeOffset Since)> seen = [];
  private readonly Dictionary<string, DateTimeOffset> lastAutomatic = [];
  private CancellationTokenSource? loop;

  public CodeBackupActions(CodeBackupProjects projects, CodeBackupLedger ledger, ICodeBackupAccount account, ICodeBackupGit git, string host = "github.com",
    string? computer = null, string? computerTitle = null, Func<CodeBackupProjectCode.Bounds>? bounds = null, Func<bool>? network = null,
    Func<DateTimeOffset>? now = null, string? workArea = null)
  {
    Projects = projects; Ledger = ledger; this.account = account; this.git = git; this.host = host.ToLowerInvariant();
    this.computer = computer ?? ComputerName(ledger);
    this.computerTitle = computerTitle ?? Environment.MachineName;
    this.workArea = workArea ?? (ledger.Folder is { } folder ? Path.Combine(folder, "code-backup-git") : Path.Combine(Path.GetTempPath(), "terminaldeck-code-backup-git"));
    this.bounds = bounds ?? CodeBackupProjectCode.Bounds.Live; this.network = network ?? System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable;
    this.now = now ?? (() => DateTimeOffset.UtcNow);
  }

  /// This PC's part of the backup references: its own name and a short stable id (a hash of the machine id, never the id
  /// itself; a kept random one when it cannot be read), so two PCs with the same name never share one backup area.
  public static string ComputerName(CodeBackupLedger ledger) =>
    ComputerPart(Environment.MachineName, MachineId() is { } id ? DeviceId(id) : ledger.SpareId());
  public static string? MachineId()
  {
    if (!OperatingSystem.IsWindows()) return null;
    try { return Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", null) as string; }
    catch (Exception error) when (error is System.Security.SecurityException or IOException or UnauthorizedAccessException) { return null; }
  }
  public static string DeviceId(string hardware) =>
    Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("TD-CODE-BACKUP-1\n" + hardware.ToUpperInvariant())))[..8];
  /// "<readable name>-<id>", one reference part.
  public static string ComputerPart(string name, string id)
  {
    var readable = CodeBackupPlan.Part(name);
    return CodeBackupPlan.Part(readable[..Math.Min(60, readable.Length)] + "-" + CodeBackupPlan.Part(id));
  }

  // ---- the page and the tool read through this ----

  /// The report with each project's mode, Get-the-code home, unfinished downloads and last action line filled in.
  public async Task<CodeBackupReport> Decorate(CodeBackupReport report)
  {
    var login = await account.Login();
    var repositories = login is null ? [] : await account.Repositories();
    var getting = Ledger.AllGetting;
    var rows = new List<CodeBackupProject>();
    foreach (var original in report.Projects)
    {
      var row = original.Clone();
      if (getting.TryGetValue(row.Id, out var open))
      {
        row.Getting = true; row.Problem = null; row.HasFolder = true; row.IsRepository = false; row.Parts = []; row.GetFrom = open.Home;
      }
      else if (row.State == CodeBackupState.CodeNotHere) row.GetFrom = Ledger.Home(row.Id) ?? Match(row.Name, repositories, login);
      row.Mode = Mode(row.Id, row.Home, repositories, login, row.Visibility);
      lock (gate) row.Note = notes.GetValueOrDefault(row.Id);
      row.Organisation = Organisation(row.Home, login);
      row.MadeHome = row.Home is { } home && Ledger.IsMade(home);
      row.HomeLink = Link(host, row.Home);
      foreach (var part in row.Parts) part.HomeLink = Link(host, part.Home);
      if (Ledger.SentAt(row.Id) is { } sent) { row.SentAt = sent; row.SentFrom = computerTitle; }
      rows.Add(row);
    }
    return new(rows, report.SignedInToGitHub ?? (login is not null), report.CheckedAt) { AutomaticWaits = !Ledger.FirstBackupDone };
  }

  /// The stored choice. Otherwise: Manual on this PC until a "Back up now" here has finished successfully; from then on
  /// Automatic for a project whose home is PRIVATE on HIS OWN account, else Manual.
  public CodeBackupMode Mode(string projectId, string? home, IReadOnlyList<CodeBackupRepo> repositories, string? login, CodeBackupVisibility visibility = CodeBackupVisibility.NotChecked)
  {
    if (Organisation(home, login) is not null) return Ledger.Mode(projectId) == CodeBackupMode.Off ? CodeBackupMode.Off : CodeBackupMode.Manual;
    if (Ledger.Mode(projectId) is { } stored) return stored;
    if (!Ledger.FirstBackupDone) return CodeBackupMode.Manual;
    if (home is null || login is null || !string.Equals(home.Split('/')[0], login, StringComparison.OrdinalIgnoreCase)) return CodeBackupMode.Manual;
    if (visibility == CodeBackupVisibility.Private) return CodeBackupMode.Automatic;
    return repositories.FirstOrDefault(r => string.Equals(r.NameWithOwner, home, StringComparison.OrdinalIgnoreCase))?.IsPrivate == true ? CodeBackupMode.Automatic : CodeBackupMode.Manual;
  }

  /// A GitHub repository for a project whose code is not here: one named as this app names homes (his own account first),
  /// else the only repository of that name he can see.
  public static string? Match(string name, IReadOnlyList<CodeBackupRepo> repositories, string? login)
  {
    var wanted = CodeBackupNames.Repository(name);
    var named = repositories.Where(r => string.Equals(r.Name, wanted, StringComparison.OrdinalIgnoreCase)).ToList();
    if (login is not null && named.FirstOrDefault(r => string.Equals(r.Owner, login, StringComparison.OrdinalIgnoreCase)) is { } own) return own.NameWithOwner;
    return named.Count == 1 ? named[0].NameWithOwner : null;
  }

  /// The app's own repository for one of his repositories: named by a hash of his Git folder's full path.
  public static string Shadow(string area, string gitDir) =>
    Path.Combine(area, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(CodeBackupProjectCode.Resolved(gitDir).ToLowerInvariant())))[..24] + ".git");

  /// The owner of a home that is not on his own account; null for his own (or no home, or not signed in).
  public static string? Organisation(string? home, string? login)
  {
    if (home is null || login is null) return null;
    var owner = home.Split('/')[0];
    return string.Equals(owner, login, StringComparison.OrdinalIgnoreCase) ? null : owner;
  }

  public string? Note(string projectId) { lock (gate) return notes.GetValueOrDefault(projectId); }
  public async Task<bool> SignedIn() => await account.Login() is not null;

  public async Task<Target?> TargetOf(string projectId) => (await Projects.List()).FirstOrDefault(p => p.Id == projectId) is { } project ? await TargetOf(project) : null;
  public async Task<Target?> TargetNamed(string name)
  {
    var wanted = name.Trim();
    return (await Projects.List()).FirstOrDefault(p => string.Equals(p.Name, wanted, StringComparison.CurrentCultureIgnoreCase)) is { } project ? await TargetOf(project) : null;
  }
  private async Task<Target> TargetOf(CodeBackupProjectRef project)
  {
    var (row, _) = await Projects.Fresh(project);
    var folder = project.Folders.FirstOrDefault() is { } first ? ShortPath(first) : null;
    var login = await account.Login();
    if (Ledger.Getting(project.Id) is { } getting) return new(project.Id, project.Name, host + "/" + getting.Home, false, null, folder);
    if (row.State == CodeBackupState.CodeNotHere)
    {
      var repositories = login is null ? [] : await account.Repositories();
      var found = Ledger.Home(project.Id) ?? Match(project.Name, repositories, login);
      return new(project.Id, project.Name, found is null ? null : host + "/" + found, false, null, folder);
    }
    if (row.Home is { } home) return new(project.Id, project.Name, host + "/" + home, false, Organisation(home, login), folder);
    if (row.OtherHost is null && login is not null) return new(project.Id, project.Name, host + "/" + login + "/" + CodeBackupNames.Repository(project.Name), true, null, folder);
    return new(project.Id, project.Name, null, false, null, folder);
  }
  /// A folder as the approval line names it: "~\Projects\Site" inside the user folder, else the full path.
  public static string ShortPath(string folder)
  {
    var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    return profile.Length > 0 && CodeBackupProjectCode.Inside(folder, profile) ? "~" + CodeBackupProjectCode.Resolved(folder)[CodeBackupProjectCode.Resolved(profile).Length..] : folder;
  }

  /// The home's own page on GitHub, for the row's link; null without a home or with an unreadable name.
  public static string? Link(string host, string? home)
  {
    if (home is null || home.Split('/').Length != 2) return null;
    return Uri.TryCreate("https://" + host + "/" + home, UriKind.Absolute, out var url) && url.Host.Length > 0 ? url.AbsoluteUri : null;
  }

  // ---- Automatic / Manual / Off ----

  /// Per project only; never the per-PC "first Back up now" mark. Automatic is refused for a home not on his own account.
  public async Task SetMode(string projectId, CodeBackupMode mode)
  {
    if (mode == CodeBackupMode.Automatic && (await Projects.List()).FirstOrDefault(p => p.Id == projectId) is { } project)
    {
      var home = (await Projects.Fresh(project)).Row.Home;
      if (Organisation(home, await account.Login()) is not null) mode = CodeBackupMode.Manual;
    }
    Ledger.SetMode(projectId, mode);
    lock (gate) seen.Remove(projectId);
    Projects.Forget(projectId);
  }

  // ---- Back up now ----

  private bool Claim(string projectId) { lock (gate) return busy.Add(projectId); }
  private void Release(string projectId) { lock (gate) busy.Remove(projectId); }

  /// `byHand`: his own click on the page. Only that marks the first Back up now on this PC; a tool call never does.
  public async Task<Outcome> BackUp(string projectId, bool automatic = false, bool byHand = false, Action<string>? progress = null)
  {
    if ((await Projects.List()).FirstOrDefault(p => p.Id == projectId) is not { } project) return new(false, "This project is not on this PC");
    if (!Claim(projectId)) return new(false, "Already working on this project");
    try
    {
      var outcome = await BackUp(project, automatic, progress ?? (_ => { }));
      if (byHand && !automatic && outcome.Ok) Ledger.SetFirstBackupDone();
      if (outcome.Ok) Ledger.SetSent(projectId, now().ToUnixTimeMilliseconds());
      if (!automatic || !outcome.Ok) lock (gate) notes[projectId] = outcome.Line;
      Projects.Forget(projectId);
      return outcome;
    }
    finally { Release(projectId); }
  }

  private static readonly IReadOnlyDictionary<string, string> NoEnvironment = new Dictionary<string, string>();

  private async Task<Outcome> BackUp(CodeBackupProjectRef project, bool automatic, Action<string> progress)
  {
    if (Ledger.Getting(project.Id) is not null) return new(false, "Not backed up: Get the code has not finished");
    if (await account.Login() is not { } login) return new(false, "Connect GitHub first");
    var fence = bounds();
    progress("Backing up · reading the folder");
    var (row, places) = await Projects.Fresh(project);
    if (row.Problem is { } problem) return new(false, "Not backed up: " + problem);
    if (row.WaitingForCode || row.State == CodeBackupState.CodeNotHere) return new(false, "Code not on this PC yet");
    if (places.Count == 0)
    {
      // A plain folder of his (no Git yet): it becomes its own repository, so it can have a home.
      var folder = project.Folders.FirstOrDefault(Directory.Exists);
      if (folder is null || CodeBackupProjectCode.WaitingForCode(folder, fence) || AtOrAboveProtected(folder, fence) || CodeBackupDisk.Exists(Path.Combine(folder, ".git")))
        return new(false, "No code folder on this PC");
      if (CodeBackupProjectCode.NearestTop(folder) is { } above && !string.Equals(CodeBackupProjectCode.Resolved(above), CodeBackupProjectCode.Resolved(folder), StringComparison.OrdinalIgnoreCase)
          && await CodeBackupProjectCode.TracksInside(CodeBackupProjectCode.Resolved(above), CodeBackupProjectCode.Resolved(folder), Probe()))
        return new(false, "Not backed up: its files are kept by the Git folder above it");
      // Checked again right before `init`: a `.git` that appeared meanwhile is his.
      if (!CodeBackupDisk.Exists(Path.Combine(folder, ".git")))
      {
        var made = await git.RunAsync(folder, ["init", "-q", "--initial-branch=main"], NoEnvironment, 30_000, 65_536);
        if (!made.Ok) return new(false, "Not backed up: Git could not start in the folder");
        if (!WriteExclude(Path.Combine(folder, ".git"))) return new(false, "Not backed up: Git could not start in the folder");
      }
      (row, places) = await Projects.Fresh(project);
      if (places.Count == 0) return new(false, "Not backed up: the folder could not be read");
    }
    var sent = 0; var skipped = new List<string>(); var leftOut = new List<CodeBackupCoverage.LeftOutFile>(); var homes = new List<string>(); var failures = new List<string>();
    var largeFiles = false;
    for (var index = 0; index < places.Count; index++)
    {
      var place = places[index];
      if (!await Owned(place, project, fence)) { failures.Add("a folder above the project is not its code"); continue; }
      var label = places.Count > 1 ? Path.GetFileName(place.Top) + ": " : "";
      if (CodeBackupSend.GitBusy(place.GitDir) is { } busyWith) { failures.Add(label + "Git is in the middle of " + busyWith); continue; }
      var found = await Home(place, index == 0, project, login, automatic, progress);
      if (found.Failure is { } line) { if (index == 0) failures.Add(label + line); else skipped.Add(label + line); continue; }
      var home = found.Home!;
      if (await account.Transport(home) is not { } transport) { failures.Add("Connect GitHub first"); continue; }
      progress("Backing up · sending to " + host + "/" + home);
      var realNames = false;
      if (CodeBackupPlan.RealNamesAllowed) realNames = await UsesRealNames(home);
      var result = await new CodeBackupSend(git, place.Top, place.GitDir, found.Remote!, transport, realNames, computer, Ledger, now(), Shadow(workArea, place.GitDir)).Perform();
      if (result.BecameLoud) Ledger.MarkLoud(home);
      if (result.Failure is { } failure) failures.Add(label + failure);
      sent += result.Sent; skipped.AddRange(result.Skipped.Select(s => label + s)); leftOut.AddRange(result.LeftOut);
      if (index == 0) { homes.Add(home); Ledger.SetHome(project.Id, home); }
      if (UsesLfs(place.Top)) largeFiles = true;
    }
    var text = failures.Count == 0 ? (homes.Count > 0 ? "Backed up to " + host + "/" + homes[0] : "Backed up") : "Not backed up: " + failures[0];
    if (leftOut.Count > 0)
    {
      var secret = leftOut.Count(l => l.Reason == "secret file");
      var why = secret == leftOut.Count ? "secret files" : secret == 0 ? "over 50 MB" : "secret files, over 50 MB";
      text += " · " + leftOut.Count + " " + (leftOut.Count == 1 ? "file" : "files") + " left out (" + why + ")";
    }
    if (skipped.Count > 0) text += " · " + skipped[0] + (skipped.Count > 1 ? " · " + (skipped.Count - 1) + " more not sent" : "");
    if (largeFiles) text += " · " + LfsLine;
    if (failures.Count == 0 && sent == 0 && skipped.Count == 0 && leftOut.Count == 0) text += " · nothing new to send";
    return new(failures.Count == 0, text);
  }

  private sealed record Found(string? Home, string? Remote, string? Failure);

  /// The repository's GitHub home and whether he may send there; for the project's own folder with no home at all, a new
  /// PRIVATE home on his account (only on his click, or with Automatic chosen by him).
  private async Task<Found> Home(CodeBackupReader.Place place, bool main, CodeBackupProjectRef project, string login, bool automatic, Action<string> progress)
  {
    var remotes = (await git.RunAsync(place.Top, ["config", "--get-regexp", @"^remote\..*\.url$"], NoEnvironment, 10_000, 65_536)).Output;
    var addresses = CodeBackupReader.Remotes(remotes);
    if ((addresses.FirstOrDefault(a => a.Name == "origin") ?? addresses.FirstOrDefault()) is { } chosen)
    {
      if (CodeBackupReader.GitHubHome(chosen.Url, host) is not { } home) return new(null, null, "its home is " + (CodeBackupReader.Host(chosen.Url) ?? "another place") + ", not GitHub");
      var mirror = await git.RunAsync(place.Top, ["config", "--get", "remote." + chosen.Name + ".mirror"], NoEnvironment, 10_000, 4096);
      if (mirror.Output.Trim() == "true") return new(null, null, "its home is set up as a mirror; not sent");
      var own = string.Equals(home.Split('/')[0], login, StringComparison.OrdinalIgnoreCase);
      if (await account.Repository(home) is not { } repository) return new(null, null, "no access to " + host + "/" + home);
      if (!own && !main) return new(null, null, host + "/" + home + " is not on your account; not backed up");
      if (!own && automatic) return new(null, null, host + "/" + home + " is an organisation's home: Back up now only");
      if (!own && !repository.CanPush) return new(null, null, "no permission to send to " + host + "/" + home);
      if (!repository.IsPrivate) return new(null, null, "its home " + host + "/" + home + " is public; backups go only to a private home");
      return new(repository.NameWithOwner, chosen.Name, null);
    }
    if (!main) return new(null, null, "no GitHub home");
    if (automatic && Ledger.Mode(project.Id) != CodeBackupMode.Automatic) return new(null, null, "no GitHub home yet");
    progress("Backing up · making a private home on GitHub");
    var made = await MakeHome(project, login);
    if (made.Failure is { } failure) return new(null, null, failure);
    var repo = made.Repo!;
    var added = await git.RunAsync(place.Top, ["remote", "add", "origin", "https://" + host + "/" + repo.NameWithOwner + ".git"], NoEnvironment, 10_000, 65_536);
    if (!added.Ok) return new(null, null, "the new home could not be set in the folder");
    Ledger.SetHome(project.Id, repo.NameWithOwner);
    Ledger.MadeHome(repo.NameWithOwner);
    return new(repo.NameWithOwner, "origin", null);
  }

  /// The repository keeps large files with Git LFS (its own `.gitattributes`); those are not copied by a backup.
  public static bool UsesLfs(string top)
  {
    try
    {
      var file = new FileInfo(Path.Combine(top, ".gitattributes"));
      return file.Exists && file.Length < 1_048_576 && File.ReadAllText(file.FullName).Contains("filter=lfs", StringComparison.Ordinal);
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }

  /// `.git/info/exclude` of a `.git` the app has just made (never one of his): heavy folders and the secret names. Written
  /// only when the file is missing or still Git's untouched template; a file with any rule of his is left as it is.
  public static bool WriteExclude(string gitDir)
  {
    var info = Path.Combine(gitDir, "info"); var file = Path.Combine(info, "exclude");
    try
    {
      if (File.Exists(file))
      {
        var text = File.ReadAllText(file);
        if (text.StartsWith(CodeBackupReader.ExcludeMarker, StringComparison.Ordinal)) return true;
        var untouched = text.Split('\n', '\r').All(l => l.Trim().Length == 0 || l.StartsWith('#'));
        if (!untouched) return true;
      }
      Directory.CreateDirectory(info);
      File.WriteAllText(file + ".tmp", CodeBackupReader.ExcludeText);
      File.Move(file + ".tmp", file, overwrite: true);
      return true;
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
  }

  private readonly Dictionary<string, (bool Quiet, DateTimeOffset At)> quietAnswers = [];
  private async Task<bool> UsesRealNames(string home)
  {
    if (!Ledger.UsesRealNames(home)) return false;
    var key = home.ToLowerInvariant();
    lock (gate) if (quietAnswers.TryGetValue(key, out var kept) && (now() - kept.At).TotalSeconds < 3_600) return kept.Quiet;
    var quiet = await account.Quiet(home);
    lock (gate) quietAnswers[key] = (quiet, now());
    if (!quiet) Ledger.MarkLoud(home);
    return quiet;
  }

  private sealed record Made(CodeBackupRepo? Repo, string? Failure);
  /// Named after the project ("my-site", then "my-site-2" … when taken). A home this app already made for the same project
  /// on his account (same name, private, described as this project) is used again instead of a second one.
  private async Task<Made> MakeHome(CodeBackupProjectRef project, string login)
  {
    var description = CodeBackupNames.Description(project.Name);
    var baseName = CodeBackupNames.Repository(project.Name);
    var existing = await account.Repositories();
    if (existing.FirstOrDefault(r => string.Equals(r.Owner, login, StringComparison.OrdinalIgnoreCase) && r.IsPrivate && r.Description == description
        && (string.Equals(r.Name, baseName, StringComparison.OrdinalIgnoreCase) || r.Name.StartsWith(baseName + "-", StringComparison.OrdinalIgnoreCase))) is { } again)
      return new(again, null);
    foreach (var name in CodeBackupNames.Candidates(baseName))
    {
      switch (await account.Create(name, description))
      {
        case CodeBackupCreated.Made made:
          if (!made.Repo.IsPrivate) return new(null, "GitHub made " + host + "/" + made.Repo.NameWithOwner + " public; nothing was sent");
          return new(made.Repo, null);
        case CodeBackupCreated.Taken: continue;
        case CodeBackupCreated.Refused refused: return new(null, refused.Reason);
      }
    }
    return new(null, "every name for a new home is taken");
  }

  private CodeBackupProjectCode.Probe Probe() => async (cwd, arguments) =>
  {
    var outcome = await git.RunAsync(cwd, arguments, NoEnvironment, 15_000, 64 * 1024);
    return outcome.Missing ? null : outcome.Output;
  };

  private async Task<bool> Owned(CodeBackupReader.Place place, CodeBackupProjectRef project, CodeBackupProjectCode.Bounds fence)
  {
    if (AtOrAboveProtected(place.Top, fence)) return false;
    foreach (var folder in project.Folders.Where(Path.IsPathFullyQualified))
    {
      if (CodeBackupProjectCode.Inside(place.Top, folder)) return true;
      if (await CodeBackupProjectCode.Owns(place.Top, folder, fence, Probe())) return true;
    }
    return false;
  }

  /// The home folder, the Terminal Deck folder, or a folder above either: never backed up as a project's code.
  public static bool AtOrAboveProtected(string path, CodeBackupProjectCode.Bounds fence)
  {
    foreach (var home in fence.Homes) if (home.Length > 0 && CodeBackupProjectCode.Inside(home, path)) return true;
    return fence.Base is { Length: > 0 } b && CodeBackupProjectCode.Inside(b, path);
  }

  // ---- Get the code ----

  public async Task<Outcome> GetCode(string projectId, Action<string>? progress = null)
  {
    if ((await Projects.List()).FirstOrDefault(p => p.Id == projectId) is not { } project) return new(false, "This project is not on this PC");
    if (!Claim(projectId)) return new(false, "Already working on this project");
    try
    {
      var outcome = await GetCode(project, progress ?? (_ => { }));
      lock (gate) notes[projectId] = outcome.Line;
      Projects.Forget(projectId);
      return outcome;
    }
    finally { Release(projectId); }
  }

  private async Task<Outcome> GetCode(CodeBackupProjectRef project, Action<string> progress)
  {
    if (await account.Login() is not { } login) return new(false, "Connect GitHub first");
    var getting = Ledger.Getting(project.Id);
    if (getting is null)
    {
      var (row, _) = await Projects.Fresh(project);
      var fence = bounds();
      var folder = project.Folders.FirstOrDefault(f => CodeBackupProjectCode.WaitingForCode(f, fence));
      if (row.State != CodeBackupState.CodeNotHere || folder is null)
        return new(false, row.IsRepository ? "The code is already on this PC" : "Code not got: the project's folder holds other files");
      var repositories = await account.Repositories();
      if ((Ledger.Home(project.Id) ?? Match(project.Name, repositories, login)) is not { } home) return new(false, "No GitHub home found for this project");
      getting = new(home, folder, CodeBackupGetCode.Temporary(folder), now().ToUnixTimeMilliseconds());
      Ledger.SetGetting(project.Id, getting);
    }
    if (await account.Transport(getting.Home) is not { } transport) return new(false, "Connect GitHub first");
    try
    {
      var (branch, kept, large) = await new CodeBackupGetCode(git, transport, "https://" + host + "/" + getting.Home + ".git", getting.Folder, getting.Temporary, progress).Perform();
      Ledger.SetGetting(project.Id, null);
      Ledger.SetHome(project.Id, getting.Home);
      Ledger.SetKept(project.Id, kept);
      var line = "Code is here" + (branch is null ? "" : " · branch " + branch);
      if (large) line += " · " + LfsLine;
      if (kept.Count > 0) line += kept.Count == 1 ? " · kept your " + kept[0] + " (it differs from GitHub's)" : " · kept " + kept.Count + " of your files that differ from GitHub's";
      return new(true, line);
    }
    catch (CodeBackupGetCode.Failure failure)
    {
      if (failure.Final)
      {
        Ledger.SetGetting(project.Id, null);
        CodeBackupDisk.Delete(getting.Temporary);
      }
      return new(false, failure.Plain);
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
    {
      return new(false, "The download stopped. Get the code again to continue");
    }
  }

  // ---- Automatic ----

  public void Start()
  {
    lock (gate)
    {
      if (loop is not null) return;
      loop = new CancellationTokenSource();
    }
    var token = loop.Token;
    _ = Task.Run(async () =>
    {
      while (!token.IsCancellationRequested)
      {
        try { await Task.Delay(TimeSpan.FromSeconds(LookSeconds), token); } catch (OperationCanceledException) { return; }
        try { await Look(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { }
      }
    }, token);
  }
  public void Stop() { lock (gate) { loop?.Cancel(); loop = null; } }

  /// One automatic look at every project set (or defaulted) to Automatic.
  public async Task Look()
  {
    if (!network()) return;
    if (await account.Login() is not { } login) return;
    var repositories = await account.Repositories();
    foreach (var project in await Projects.List())
    {
      bool working; lock (gate) working = busy.Contains(project.Id);
      if (working || Ledger.Getting(project.Id) is not null) continue;
      // A project that is Manual or Off (stored, or Manual because no Back up now has finished here yet) is not read.
      var stored = Ledger.Mode(project.Id);
      if (stored is CodeBackupMode.Manual or CodeBackupMode.Off || (stored is null && !Ledger.FirstBackupDone)) { lock (gate) seen.Remove(project.Id); continue; }
      var (row, places) = await Projects.Fresh(project);
      if (Mode(project.Id, row.Home, repositories, login) != CodeBackupMode.Automatic || row.Problem is not null || !row.HasFolder || row.WaitingForCode) { lock (gate) seen.Remove(project.Id); continue; }
      var check = row.Clone(); check.Mode = CodeBackupMode.Automatic;
      if (check.State is not (CodeBackupState.CommitsNotOnGitHub or CodeBackupState.FilesChanged or CodeBackupState.SetAside or CodeBackupState.NoHome)) { lock (gate) seen.Remove(project.Id); continue; }
      if (places.Any(p => CodeBackupSend.GitBusy(p.GitDir) is not null)) { lock (gate) seen.Remove(project.Id); continue; }
      if (await SettleMark(project, row, places) is not { } mark) continue;
      var at = now();
      bool run = false;
      lock (gate)
      {
        if (seen.TryGetValue(project.Id, out var before) && before.Mark == mark)
        {
          var settled = (at - before.Since).TotalSeconds >= SettleSeconds - 1;
          var spaced = !lastAutomatic.TryGetValue(project.Id, out var last) || (at - last).TotalSeconds >= GapSeconds;
          if (settled && spaced) { lastAutomatic[project.Id] = at; seen.Remove(project.Id); run = true; }
        }
        else seen[project.Id] = (mark, at);
      }
      if (run) await BackUp(project.Id, automatic: true);
    }
  }

  /// What must stay the same for work to count as settled: the row's facts, Git's own change marks, and each changed
  /// file's size and modification time. Read-only.
  public static async Task<string?> SettleMark(CodeBackupProjectRef project, CodeBackupProject row, IReadOnlyList<CodeBackupReader.Place> places)
  {
    var parts = row.Parts.Count == 0 ? [row] : row.Parts;
    var tops = places.Select(p => p.Top).ToList();
    var mark = await CodeBackupDisk.Run(5, () =>
    {
      var text = new StringBuilder(CodeBackupProjects.Mark(project, places));
      for (var i = 0; i < parts.Count; i++)
      {
        var part = parts[i];
        text.Append('#').Append(part.CommitCount).Append('.').Append(part.ChangedCount).Append('.').Append(part.SetAsideCount).Append('.').Append(part.LastCommitAt ?? 0);
        var top = i < tops.Count ? tops[i] : null;
        foreach (var name in part.ChangedFiles.Take(CodeBackupProject.ListLimit)) text.Append('|').Append(name).Append('@').Append(top is null ? "?" : CodeBackupDisk.Stamp(Path.Combine(top, name)));
      }
      return text.ToString();
    });
    return mark.Done ? mark.Value : null;
  }
}

/// Names for a new GitHub home.
public static class CodeBackupNames
{
  /// The project's name as a GitHub repository name: letters, digits, '.', '_' and '-', lower case, at most 90.
  public static string Repository(string name)
  {
    var built = new StringBuilder();
    foreach (var c in name.ToLowerInvariant())
    {
      if (char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-') built.Append(c);
      else if (built.Length == 0 || built[^1] != '-') built.Append('-');
    }
    var text = built.ToString().Trim('-', '.');
    if (text.Length == 0 || text is "." or "..") text = "project";
    return text[..Math.Min(90, text.Length)];
  }
  /// "name", then "name-2" … "name-9".
  public static IReadOnlyList<string> Candidates(string baseName) => [baseName, .. Enumerable.Range(2, 8).Select(n => baseName + "-" + n)];
  /// The description a new home carries, so another computer of his finds it for "Get the code".
  public static string Description(string projectName) => "Terminal Deck project: " + projectName;
}

/// The one live Code backup the app installs at start, for the page and the code.* tools.
public static class CodeBackupHolder
{
  public static CodeBackupActions? Installed { get; set; }
}
