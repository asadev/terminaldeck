using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.Core.Accounts;

public sealed record NewSessionAgentChoice(string Id, string Name, string ProjectId, string Provider, bool Lead);

// Agent tools for everything Coding AIs and New session offer on Windows:
// API-key accounts, account colours, the app-wide model and effort, and the
// New session choices. Reads run freely; every change asks the person.
public static class AccountMcp
{
  private const string S = "{\"type\":\"string\",\"maxLength\":2048}";
  private const string Provider = "{\"type\":\"string\",\"enum\":[\"claude\",\"codex\",\"gemini\"]}";
  private static McpToolSpec Spec(string id, McpTier tier, string properties = "", string required = "") =>
    new(id, id.Replace('.', '_'), tier, JsonDocument.Parse("{\"type\":\"object\",\"properties\":{" + properties + "},\"additionalProperties\":false" +
      (required.Length == 0 ? "" : ",\"required\":[" + required + "]") + "}").RootElement.Clone());
  public static IReadOnlyList<McpToolSpec> Specs { get; } = [
    Spec("accounts.api", McpTier.Alter,
      "\"action\":{\"type\":\"string\",\"enum\":[\"read\",\"add\",\"update\",\"check\",\"remove\"]},\"accountId\":" + S + ",\"agent\":" + Provider + ",\"name\":" + S +
      ",\"kind\":{\"type\":\"string\",\"enum\":[\"anthropic\",\"anthropic-token\",\"openai\",\"compatible\",\"compatible-local\",\"gemini\"]},\"baseUrl\":" + S + ",\"workspaceId\":" + S + ",\"model\":" + S + ",\"key\":" + S,
      "\"action\""),
    Spec("accounts.color", McpTier.Alter, "\"accountId\":" + S + ",\"color\":{\"type\":\"string\",\"enum\":[\"blue\",\"green\",\"amber\",\"orange\",\"red\",\"purple\",\"teal\",\"pink\"]}", "\"accountId\",\"color\""),
    Spec("settings.launch_models", McpTier.Alter, "\"action\":{\"type\":\"string\",\"enum\":[\"read\",\"set\"]},\"agent\":" + Provider + ",\"model\":" + S + ",\"effort\":{\"type\":\"string\",\"enum\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}", "\"action\""),
    Spec("sessions.new_choices", McpTier.Read, "\"agent\":" + Provider + ",\"accountId\":" + S + ",\"projectId\":" + S + ",\"query\":" + S),
  ];
  public static McpTier Tier(McpToolSpec spec, JsonElement arguments)
  {
    var action = arguments.TryGetProperty("action", out var a) ? a.GetString() : null;
    return spec.Id switch
    {
      "accounts.api" => action == "read" ? McpTier.Read : McpTier.Alter,
      "settings.launch_models" => action == "read" ? McpTier.Read : McpTier.Alter,
      _ => spec.Tier
    };
  }

  public static void Register(McpDoor door, AccountService accounts, ApiAccountService? api, GeneralSettings general,
    Func<IReadOnlyList<Project>> projects, Func<IEnumerable<string>> recentFolders, Func<IEnumerable<NewSessionAgentChoice>> agents, Func<string, bool> inUse)
  {
    string? T(JsonElement a, string name) => a.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    door.Register("accounts.api", async (c, a, ct) =>
    {
      var action = T(a, "action")!;
      var draft = new ApiAccountDraft(T(a, "kind") ?? "", T(a, "baseUrl"), T(a, "workspaceId"), T(a, "model"));
      if (action == "add")
      {
        c.Require("settings", "accounts");
        if (api is null) throw new McpRefusal("API-key accounts are unavailable in this copy.");
        var provider = T(a, "agent") ?? throw new McpRefusal("Choose claude, codex or gemini.");
        if (draft.Kind.Length == 0) draft = draft with { Kind = ApiKinds.For(provider)[0].Kind };
        await c.EnsureCurrentAsync(ct);
        return View(await api.AddAsync(provider, T(a, "name") ?? AgentName(provider) + " API", draft, T(a, "key"), ct), api);
      }
      var id = T(a, "accountId") ?? throw new McpRefusal("Choose an account."); c.Require("accounts", id);
      if (api is null) throw new McpRefusal("API-key accounts are unavailable in this copy.");
      switch (action)
      {
        case "read": return View(accounts.Get(id), api);
        case "update":
          var current = api.Read(id) ?? throw new McpRefusal("Choose an API-key account.");
          if (draft.Kind.Length == 0) draft = draft with { Kind = current.Kind };
          await c.EnsureCurrentAsync(ct); return View(await api.UpdateAsync(id, draft, T(a, "key"), ct), api);
        case "check": await c.EnsureCurrentAsync(ct); await api.CheckAsync(id, ct); return View(accounts.Get(id), api);
        case "remove": await c.EnsureCurrentAsync(ct); await api.RemoveAsync(id, inUse, ct); return JsonSerializer.SerializeToElement(new { removed = true });
        default: throw new McpRefusal("Choose read, add, update, check or remove.");
      }
    });
    door.Register("accounts.color", async (c, a, ct) =>
    {
      var id = T(a, "accountId")!; c.Require("accounts", id); await c.EnsureCurrentAsync(ct);
      await accounts.SetColorAsync(id, T(a, "color")!, ct); return JsonSerializer.SerializeToElement(accounts.Get(id));
    });
    door.Register("settings.launch_models", async (c, a, ct) =>
    {
      c.Require("settings", "accounts");
      if (T(a, "action") == "set")
      {
        var provider = T(a, "agent") ?? throw new McpRefusal("Choose claude, codex or gemini.");
        var saved = LaunchDefaults.For(provider, general.Read());
        await c.EnsureCurrentAsync(ct);
        general.Save(LaunchDefaults.With(general.Read(), provider, T(a, "model") ?? saved.Model, T(a, "effort") ?? saved.Effort));
      }
      return LaunchView(general.Read());
    });
    door.Register("sessions.new_choices", (c, a, ct) =>
    {
      var provider = T(a, "agent") ?? "claude";
      var accountId = T(a, "accountId") ?? accounts.Preferred(provider)?.Id;
      var list = accounts.InstantModels(provider, accountId);
      var launch = LaunchDefaults.For(provider, general.Read());
      var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
      var allProjects = projects();
      var result = new
      {
        kinds = new[] { new { id = "chat", name = "AI chat" }, new { id = "terminal", name = "AI in a terminal" }, new { id = "shell", name = "Terminal (PowerShell)" }, new { id = "agent", name = "Agent" } },
        agents = new[] { "claude", "codex", "gemini" }.Select(p => new { id = p, name = AgentName(p) }),
        accounts = accounts.List(provider).Where(x => c.Has("accounts", x.Id)).Select(x => new { x.Id, x.Name, x.SignedIn, x.Email, authentication = x.Authentication.ToString(), x.Color, isDefault = accounts.Default(provider)?.Id == x.Id }),
        models = ModelCatalog.Merge(provider, list.Models).Select(m => new { m.Id, m.Name, efforts = ModelEfforts.For(provider, m).Select(e => new { id = e, name = ModelCatalog.EffortName(e) }) }),
        modelsSource = list.Cached ? "saved or preloaded list" : "live list",
        selected = new { model = launch.Model, effort = launch.Effort, label = ModelCatalog.Label(provider, launch.Model, launch.Effort) },
        permissionModes = TerminalDeck.Core.Chats.ChatPermissionModes.Supported(provider).Select(m => new { id = m.ToString(), name = TerminalDeck.Core.Chats.ChatPermissionModes.Label(m), explain = TerminalDeck.Core.Chats.ChatPermissionModes.Explain(m) }),
        permission = general.NewChatPermission(provider).ToString(),
        folders = NewSessionFolders.Choices(allProjects, recentFolders(), home, T(a, "query") ?? "").Where(f => c.Has("folders", f.Path)).Select(f => new { f.Path, f.Label, kind = f.Kind.ToString(), f.ProjectId }),
        projects = NewSessionProjects.Choices(allProjects).Where(p => c.Has("projects", p.Id)).Select(p => new { p.Id, p.Name, p.HomeFolder }),
        teamAgents = agents().Where(x => T(a, "projectId") is not { } project || x.ProjectId == project).Select(x => new { x.Id, x.Name, x.ProjectId, x.Provider, x.Lead })
      };
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(result));
    });
  }
  public static string AgentName(string provider) => provider switch { "claude" => "Claude Code", "codex" => "Codex", "gemini" => "Gemini", _ => provider };
  private static JsonElement View(AccountProfile account, ApiAccountService api)
  {
    var connection = api.Read(account.Id);
    return JsonSerializer.SerializeToElement(new
    {
      account.Id, account.Name, account.Provider, account.SignedIn, account.Color,
      kind = connection?.Kind, baseUrl = connection?.BaseUrl, workspaceId = connection?.WorkspaceId, model = connection?.Model,
      keySaved = connection?.CredentialReference is not null, status = ApiAccountService.Status(connection), checkedAt = connection?.CheckedAt
    });
  }
  private static JsonElement LaunchView(GeneralPreferences preferences) => JsonSerializer.SerializeToElement(new[] { "claude", "codex", "gemini" }.Select(p =>
  {
    var (model, effort) = LaunchDefaults.For(p, preferences);
    return new { agent = p, model, effort, label = ModelCatalog.Label(p, model, effort) };
  }));
}
