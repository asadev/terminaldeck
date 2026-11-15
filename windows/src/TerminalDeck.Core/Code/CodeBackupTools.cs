using System.Globalization;
using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Code;

// The Code page's tools (port of the Mac's BackendCodeBackupTools, CLOUD-CONTRACTS-1114 §6, L5). code.projects reads the
// page's rows; code.backup_now (which also makes a private home when the project has none), code.get_code and
// code.set_mode are the page's actions and go through the door's normal approval (Alter asks the owner first). There is
// no tool that makes anything public. Names, plain states and dates; never a token, a project id or a path.
public sealed class CodeBackupTools(Func<CodeBackupActions?> installed)
{
  public const string ProjectsId = "code.projects", BackupId = "code.backup_now", GetCodeId = "code.get_code", ModeId = "code.set_mode";
  public const string Description = "The Code page as the person sees it: every project on this PC with when its code was last backed up to GitHub (the newest of their commits that is on GitHub), whether it is all there, its GitHub home and whether that is private or public (\"not checked\" when this PC is not signed in to GitHub), the branch, and what is not backed up: files changed since the last commit (submodules included), commits not on the project's GitHub home, work set aside with git stash, files that cannot go to GitHub as they are (over 50 MB, or a secret file not in any commit), and secret files that are already in the last commit. A project with several code folders lists each in folders and shows the worst. Reading never changes anything in any folder. project narrows to one project by name; refresh true reads every folder again instead of the answer kept for up to a minute.";
  public const string BackupDescription = "Backs up one project's code to its PRIVATE home on GitHub, as the Code page's Back up now does. It only ever ADDS. It writes only private backup references (refs/terminal-deck-backup/<computer>/…: their branches, tags, uncommitted work and set-aside changes), never a branch or a tag, so no deploy, workflow or CI that hangs on a push can start; pushing their real branches stays their decision. It never forces, rewrites, deletes, changes the branch the person is on, their files or their staging area, never sends secret files (.env, keys, tokens, sign-in files) or files over 50 MB, and never sends anything to a public repository. A project with no GitHub home gets a new PRIVATE repository on the person's own account, named after the project. Asks the owner first. project is the project's name as code_projects lists it.";
  public const string GetCodeDescription = "Brings a project's code from its GitHub home into its folder on this PC, as the Code page's Get the code does, for a project that shows \"code not on this PC yet\". Files already in the folder (instruction files) are kept; one that differs from GitHub's copy is kept as it is and shows as changed. A download that stopped continues where it stopped. Asks the owner first. project is the project's name.";
  public const string ModeDescription = "Sets how one project's code is backed up: automatic (after its work has not changed for 5 minutes, at most every 15 minutes, on a normal network, never while Git is busy in it; makes a private home if it has none), manual (only when Back up now is pressed) or off. Asks the owner first.";

  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [
    Spec(ProjectsId, McpTier.Read, new { type = "object", properties = new { project = new { type = "string" }, refresh = new { type = "boolean" } }, additionalProperties = false }),
    Spec(BackupId, McpTier.Alter, new { type = "object", properties = new { project = new { type = "string" } }, required = new[] { "project" }, additionalProperties = false }),
    Spec(GetCodeId, McpTier.Alter, new { type = "object", properties = new { project = new { type = "string" } }, required = new[] { "project" }, additionalProperties = false }),
    Spec(ModeId, McpTier.Alter, new { type = "object", properties = new { project = new { type = "string" }, mode = new { type = "string", @enum = new[] { "automatic", "manual", "off" } } }, required = new[] { "project", "mode" }, additionalProperties = false }),
  ];
  private static McpToolSpec Spec(string id, McpTier tier, object schema) => new(id, id.Replace('.', '_'), tier, JsonSerializer.SerializeToElement(schema));

  public void Register(McpDoor door)
  {
    if (!McpCatalogue.Load().Any(s => s.Id == ProjectsId)) return;
    foreach (var spec in Specs) { var id = spec.Id; door.Register(id, (context, args, ct) => CallAsync(id, context, args, ct)); }
  }

  private static string? S(JsonElement args, string key) => args.ValueKind == JsonValueKind.Object && args.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

  public async ValueTask<JsonElement> CallAsync(string id, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    var actions = installed() ?? throw new McpRefusal("The Code page is still starting. Try again in a moment.");
    if (id == ProjectsId)
    {
      var refresh = args.ValueKind == JsonValueKind.Object && args.TryGetProperty("refresh", out var r) && r.ValueKind == JsonValueKind.True;
      var report = await ReadAsync(actions, refresh);
      var wanted = (S(args, "project") ?? "").Trim();
      var rows = wanted.Length == 0 ? report.Projects : report.Projects.Where(p => string.Equals(p.Name, wanted, StringComparison.CurrentCultureIgnoreCase)).ToList();
      if (wanted.Length > 0 && rows.Count == 0) throw new McpRefusal("No project is called “" + wanted + "”. code_projects without project lists them all.");
      return Wire(report, rows, DateTimeOffset.Now);
    }
    await context.EnsureCurrentAsync(ct);
    var name = (S(args, "project") ?? "").Trim();
    if (name.Length == 0) throw new McpRefusal("Give project: the project's name as code_projects lists it.");
    if (!await actions.SignedIn()) throw new McpRefusal("GitHub is not connected on this PC. The owner connects it on the Code page (Connect GitHub).");
    var target = await actions.TargetNamed(name) ?? throw new McpRefusal("No project is called “" + name + "”. code_projects lists them.");
    switch (id)
    {
      case BackupId:
        if (target.Address is null) throw new McpRefusal("“" + target.Name + "” has no GitHub home this app can use (its code goes somewhere else, or GitHub is not connected).");
        return Answer(await actions.BackUp(target.ProjectId));
      case GetCodeId:
        if (target.Address is null) throw new McpRefusal("No GitHub home was found for “" + target.Name + "”.");
        return Answer(await actions.GetCode(target.ProjectId));
      case ModeId:
        var chosen = CodeBackupWordsOf.Mode(S(args, "mode")) ?? throw new McpRefusal("mode is automatic, manual or off.");
        if (chosen == CodeBackupMode.Automatic && target.Organisation is { } organisation)
          throw new McpRefusal("“" + target.Name + "” has its home on " + organisation + "'s account: Back up now only, never Automatic (everyone in " + organisation + " can see backups).");
        await actions.SetMode(target.ProjectId, chosen);
        return JsonSerializer.SerializeToElement(new { ok = true, mode = CodeBackupWordsOf.Raw(chosen) });
      default: throw new McpRefusal("That tool is not available.");
    }
  }

  /// What the page and the tool read: the Git facts, GitHub's private/public answers, then each project's actions state.
  public static async Task<CodeBackupReport> ReadAsync(CodeBackupActions actions, bool refresh)
  {
    var report = await actions.Projects.WithGitHub(await actions.Projects.Report(refresh));
    return await actions.Decorate(report);
  }

  private static JsonElement Answer(CodeBackupActions.Outcome outcome) =>
    outcome.Ok ? JsonSerializer.SerializeToElement(new { ok = true, result = outcome.Line }) : throw new McpRefusal(outcome.Line);

  private static string? Iso(long? ms) => ms is { } at ? DateTimeOffset.FromUnixTimeMilliseconds(at).ToLocalTime().ToString("yyyy-MM-ddTHH:mm:sszzz", CultureInfo.InvariantCulture) : null;

  /// The tool's answer: exactly what the page's rows say, then the lists.
  public static JsonElement Wire(CodeBackupReport report, IReadOnlyList<CodeBackupProject>? rows, DateTimeOffset now, TimeZoneInfo? zone = null)
  {
    Dictionary<string, object?> One(CodeBackupProject row)
    {
      var last = CodeBackupWords.LastBackedUp(row, now, zone);
      return new()
      {
        ["state"] = CodeBackupWordsOf.Raw(row.State),
        ["summary"] = CodeBackupWords.Summary(row, now, zone),
        ["lastBackedUp"] = last.Length == 0 ? null : last,
        ["lastBackedUpAt"] = Iso(row.LastBackedUpAt),
        ["codeFolder"] = row.FolderName,
        ["gitHubHome"] = row.Home,
        ["otherHome"] = row.OtherHost,
        ["visibility"] = row.Home is null ? null : CodeBackupWordsOf.Raw(row.Visibility),
        ["branch"] = row.IsRepository ? row.Branch ?? CodeBackupWords.NotOnBranch : null,
        ["lastCommitAt"] = Iso(row.LastCommitAt),
        ["changedSinceLastCommit"] = new { count = row.ChangedCount, names = row.ChangedFiles },
        ["commitsNotOnGitHub"] = new { count = row.CommitCount, commits = row.Commits.Select(c => new { subject = c.Subject, at = Iso(c.At) }) },
        ["setAsideChanges"] = row.SetAsideCount,
        ["cannotGoToGitHub"] = row.Held.Select(h => new { name = h.Name, why = CodeBackupWords.Reason(h.Reason) }),
        ["secretFilesInCommits"] = row.SecretsInCommits,
        ["problem"] = row.Problem,
        ["backup"] = CodeBackupWordsOf.Raw(row.Mode),
        ["uncommittedWorkBackedUpAt"] = Iso(row.ChangesCoveredAt),
        ["setAsideChangesBackedUp"] = row.SetAsideCovered,
        ["commitsBackedUpPrivately"] = new { count = row.PrivateCommitCount, notYetOnTheseGitHubBranches = row.PrivateBranches },
        ["getCodeFrom"] = row.GetFrom,
        ["lastAction"] = row.Note,
      };
    }
    var projects = (rows ?? report.Projects).Select(row =>
    {
      var pairs = new Dictionary<string, object?> { ["name"] = row.Name };
      foreach (var (k, v) in One(row)) pairs[k] = v;
      if (row.Parts.Count > 1) pairs["folders"] = row.Parts.Select(One).ToList();
      return pairs;
    }).ToList();
    return JsonSerializer.SerializeToElement(new Dictionary<string, object?>
    {
      ["signedInToGitHub"] = report.SignedInToGitHub,
      ["note"] = report.SignedInToGitHub == false ? CodeBackupWords.SignInLine : null,
      ["checkedAt"] = Iso(report.CheckedAt),
      ["projects"] = projects,
    });
  }
}
