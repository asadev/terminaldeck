using System.Text.Json;
using TerminalDeck.Core.Quality;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private Deployments? deployments;
  public Deployments Deployments => deployments ??= new(new TerminalDeck.Core.Storage.JsonStateStore<DeploymentLedger>(Root, "deployments"));
  public ProjectReadiness ProjectReadiness { get; } = new();
  public TerminalDeck.Core.Code.ICodeProcessRunner ReadinessRunner => new ReadinessProcessRunner(Root);
  private StaysFixedService? staysFixed;
  public StaysFixedService StaysFixed => staysFixed ??= new(new StaysFixedRunner(Path.Combine(AppContext.BaseDirectory, "tools", "staysfixed", "node_modules", "staysfixed")), new TerminalDeck.Core.Storage.JsonStateStore<StaysFixedPreferences>(Root, "staysfixed-preferences"));
  private ReadinessDismissals? readinessDismissals;
  public ReadinessDismissals ReadinessDismissals => readinessDismissals ??= new(new TerminalDeck.Core.Storage.JsonStateStore<ReadinessPreferences>(Root, "readiness-dismissed"));
  public Task<string> StartQualityFixAsync(string folder, string provider, string kind, CancellationToken ct = default) =>
    RunQualityFixAsync(folder, kind, new QualityAiTarget(provider), ct);
  public async Task<string> RunQualityFixAsync(string folder, string kind, QualityAiTarget target, CancellationToken ct = default)
  {
    if (kind is not ("readiness" or "staysfixed")) throw new ArgumentException("Choose Readiness or Stays Fixed.");
    var evidence = kind == "readiness" ? JsonSerializer.Serialize(await ProjectReadiness.ScanAsync(folder, target.Provider, ReadinessRunner, ct)) : StaysFixed.FullReport(folder).GetRawText();
    var prompt = (target.AddRule ? "Add a real Stays Fixed guard for the behavior the person wants to protect. Use the bundled engine's guard API and validate its human sentence name. " : "Review and fix this project's " + kind + " findings. ") + "Inspect real source and project instructions first. Explain changes and run relevant checks. Never hide a failure, waive a difference or move the known-good reference. Ask before destructive commands, installs or external changes. Evidence:\n" + evidence;
    if (prompt.Length > 7800) prompt = prompt[..7800] + "\n[Evidence excerpt truncated. Read the complete report and inspect the project.]";
    if (target.ExistingSessionId is { } existing)
    {
      var row = ProjectSessions().SingleOrDefault(r => r.Id == existing && r.Provider != "shell" && r.Status is not ("Exited" or "ended") && string.Equals(Path.GetFullPath(r.Folder), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase)) ?? throw new InvalidOperationException("Choose an active coding-AI session in this project folder.");
      ct.ThrowIfCancellationRequested();
      await SendAsync(existing, row.Mode == "chat" ? prompt : TerminalDeck.Core.Browser.BrowserContext.TerminalMessage(prompt)); return existing;
    }
    var account = target.AccountId is null ? Accounts.Preferred(target.Provider, folder) : Accounts.Get(target.AccountId);
    if (account is null || account.Provider != target.Provider) throw new InvalidOperationException("Choose a signed-in account for this coding AI.");
    account = await Accounts.RequireSignedInAsync(account.Id);
    string session;
    if (target.Chat)
    {
      var created = await Chats.CreateAsync(new(Guid.NewGuid().ToString(), target.Provider, folder, target.AddRule ? "Add a Stays Fixed rule" : "Fix " + kind, account.Id, account.HomeId, new(target.Model, target.Effort), PermissionMode: TerminalDeck.Core.Mcp.AiPermissionMode.Ask), null, ct);
      session = created.Definition.Id; await Chats.SendAsync(session, Guid.NewGuid().ToString(), prompt, cancellationToken: ct);
    }
    else
    {
      var response = await Keeper.CreateAsync(new(Guid.NewGuid().ToString(), target.Provider, folder, "Fix " + kind, account.Id, account.HomeId, InitialPrompt: prompt, Model: target.Model, Effort: target.Effort.Length == 0 ? null : target.Effort, Permission: "ask"), ct);
      session = response.Session?.Definition.Id ?? throw new IOException("The fix session did not start.");
    }
    var project = Projects.List().Where(p => !p.Folders.IsDefaultOrEmpty && p.Folders.Any(f => TerminalDeck.Core.Projects.ProjectPaths.Contains(f, folder))).OrderByDescending(p => p.Folders.Where(f => TerminalDeck.Core.Projects.ProjectPaths.Contains(f, folder)).Max(f => f.Length)).FirstOrDefault();
    if (project is not null) Projects.BindSession(session, project.Id);
    await RefreshSessionsAsync(); return session;
  }
  private void RequireQualityAiAccess(string folder)
  { if (!StaysFixed.AiSessionsEnabled(folder)) throw new InvalidOperationException("AI-session access to Stays Fixed is off for this project. The person can enable it on the Stays Fixed page after setup."); }
  private void InitializeQualityTools()
  {
    InitializeStoreTools();
    InitializeTerminalAppearanceTools();
    Door.Register("quality.access", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      StaysFixed.SetAiSessionsEnabled(folder, args.GetProperty("enabled").GetBoolean()); return JsonSerializer.SerializeToElement(new { enabled = StaysFixed.AiSessionsEnabled(folder) });
    });
    Door.Register("quality.provider-updates", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder);
      var report = await ProjectReadiness.ScanAsync(folder, args.TryGetProperty("provider", out var provider) ? provider.GetString() : null, ReadinessRunner, ct);
      using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) }; return JsonSerializer.SerializeToElement(await ReadinessProviderUpdates.CheckAsync(report, http, ct));
    });
    Door.Register("quality.reviewed-fix", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      switch (args.GetProperty("action").GetString())
      {
        case "preview-command": return JsonSerializer.SerializeToElement(await ProjectReadiness.PreviewCommandAsync(folder, args.GetProperty("fix").GetString()!, ReadinessRunner, ct));
        case "apply-command": return JsonSerializer.SerializeToElement(await ProjectReadiness.ApplyCommandAsync(folder, args.GetProperty("token").GetString()!, ReadinessRunner, ct));
        case "preview": return JsonSerializer.SerializeToElement(ProjectReadiness.PreviewChange(folder, args.GetProperty("fix").GetString()!));
        case "apply": return JsonSerializer.SerializeToElement(new { path = ProjectReadiness.ApplyChange(folder, args.GetProperty("token").GetString()!), report = ProjectReadiness.Scan(folder) });
        case "rollback": ProjectReadiness.RollbackChange(folder, args.GetProperty("token").GetString()!); return JsonSerializer.SerializeToElement(ProjectReadiness.Scan(folder));
        default: throw new ArgumentException("Choose preview, apply or rollback.");
      }
    });
    Door.Register("quality.dismiss", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      var scope = args.TryGetProperty("scope", out var chosen) && chosen.GetString() == "machine" ? "*machine*" : folder;
      ReadinessDismissals.Set(scope, args.GetProperty("id").GetString()!, args.GetProperty("hidden").GetBoolean()); return JsonSerializer.SerializeToElement(ReadinessDismissals.Hidden(scope));
    });
    Door.Register("quality.report", (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); RequireQualityAiAccess(folder); return ValueTask.FromResult(StaysFixed.FullReport(folder));
    });
    Door.Register("quality.action", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); RequireQualityAiAccess(folder); await context.EnsureCurrentAsync(ct);
      var request = JsonSerializer.Deserialize<StaysFixedRequest>(args, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
      return JsonSerializer.SerializeToElement(await StaysFixed.RunAsync(folder, request, ct));
    });
    Door.Register("quality.rule", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      RequireQualityAiAccess(folder);
      return JsonSerializer.SerializeToElement(new { path = await StaysFixed.AddRuleAsync(folder, args.GetProperty("name").GetString()!, args.GetProperty("because").GetString()!, args.GetProperty("executable").GetString()!, JsonSerializer.Deserialize<string[]>(args.GetProperty("arguments"))!, ct) });
    });
    Door.Register("quality.ai-fix", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      var kind = args.GetProperty("kind").GetString()!; if (kind == "staysfixed") RequireQualityAiAccess(folder);
      string? Optional(string key) => args.TryGetProperty(key, out var value) ? value.GetString() : null;
      var target = new QualityAiTarget(args.GetProperty("provider").GetString()!, Optional("accountId"), Optional("model") ?? "", Optional("effort") ?? "", Optional("existingSessionId"), !args.TryGetProperty("chat", out var chat) || chat.GetBoolean(), args.TryGetProperty("addRule", out var rule) && rule.GetBoolean());
      if (target.AccountId is { } account) context.Require("accounts", account); if (target.ExistingSessionId is { } existing) context.Require("sessions", existing);
      var session = await RunQualityFixAsync(folder, kind, target, ct); if (target.ExistingSessionId is null) context.NoteSessionStarted(session); return JsonSerializer.SerializeToElement(new { sessionId = session });
    });
    Door.Register("deployments.read", (context, args, ct) =>
    {
      var project = args.TryGetProperty("projectId", out var p) ? p.GetString() : null;
      var session = args.TryGetProperty("sessionId", out var s) ? s.GetString() : null;
      if (project is not null) context.Require("projects", project); if (session is not null) context.Require("sessions", session);
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(Deployments.Read(project, session).Where(r => context.Has("projects", r.ProjectId) && (r.SessionId is null || context.Has("sessions", r.SessionId)))));
    });
    Door.Register("deployments.report", async (context, args, ct) =>
    {
      var project = args.GetProperty("projectId").GetString()!; context.Require("projects", project); _ = Projects.Get(project);
      var session = args.TryGetProperty("sessionId", out var s) ? s.GetString() : null; if (session is not null) context.Require("sessions", session);
      await context.EnsureCurrentAsync(ct);
      var steps = JsonSerializer.Deserialize<DeploymentStep[]>(args.GetProperty("steps"), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
      return JsonSerializer.SerializeToElement(Deployments.Report(project, session, args.TryGetProperty("runId", out var id) ? id.GetString() : null, args.GetProperty("title").GetString()!, context.Grant.CallerId, steps));
    });
    Door.Register("quality.readiness", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder);
      return JsonSerializer.SerializeToElement(await ProjectReadiness.ScanAsync(folder, args.TryGetProperty("provider", out var provider) ? provider.GetString() : null, ReadinessRunner, ct));
    });
    Door.Register("quality.fix", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      return args.GetProperty("action").GetString() switch
      {
        "preview" => JsonSerializer.SerializeToElement(ProjectReadiness.Preview(folder, args.GetProperty("fix").GetString()!)),
        "apply" => JsonSerializer.SerializeToElement(new { path = ProjectReadiness.Apply(folder, args.GetProperty("token").GetString()!) }),
        _ => throw new ArgumentException("Choose preview or apply.")
      };
    });
    Door.Register("quality.staysfixed", async (context, args, ct) =>
    {
      var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder); await context.EnsureCurrentAsync(ct);
      RequireQualityAiAccess(folder);
      return JsonSerializer.SerializeToElement(await StaysFixed.RunAsync(folder, args.GetProperty("action").GetString()!, ct));
    });
  }
}
