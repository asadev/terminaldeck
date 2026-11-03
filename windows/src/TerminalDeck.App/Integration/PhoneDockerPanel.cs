using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private sealed record PhoneDockerReview(string Token, string Server, DockerAppDraft Draft, string Action, DateTimeOffset ExpiresAt);
  private readonly Dictionary<string, PhoneDockerReview> phoneDockerReviews = [];
  private PhonePanelOwner PhoneDockerPanel() => new("docker", true, async (device, request, ct) =>
  {
    var rows = new JsonArray(); var scope = PanelText(request, "scope"); var caller = PhoneServerCaller(device);
    foreach (var server in Servers.List(caller).Where(s => scope is null || s.Id == scope).Take(20))
    {
      var actions = new JsonArray();
      if (!server.Access.LookOnly && device.Access == PhoneAccess.Full && Servers is ServerService)
      {
        var fields = DockerPhoneFields(server); actions.Add(PanelAction("preview-app", "Review app configuration", fields));
        actions.Add(PanelAction("read-config", "Read an app configuration", PanelField("name", "App name", "my-app", true), PanelField("directory", "App folder", server.Access.Folders.FirstOrDefault() ?? "", true)));
      }
      rows.Add(new JsonObject { ["id"] = "server:" + server.Id, ["title"] = server.Name, ["group"] = "Servers", ["detail"] = server.Access.LookOnly ? "Look only" : "App changes ask for approval", ["actions"] = actions });
      foreach (var app in (await Servers.AppsAsync(server.Id, caller, ct)).Take(100))
        rows.Add(new JsonObject { ["id"] = server.Id + ":" + app.Id, ["title"] = app.Name, ["group"] = server.Name, ["detail"] = app.Image + " · " + app.Ports, ["value"] = app.State,
          ["actions"] = server.Access.LookOnly ? new JsonArray(PanelAction("logs", "Read logs")) : new JsonArray(PanelAction("logs", "Read logs"), PanelAction("start", "Start"), PanelAction("stop", "Stop"), PanelAction("restart", "Restart")) });
    }
    PhoneDockerReview? review; lock (phoneDockerReviews)
    {
      foreach (var expired in phoneDockerReviews.Where(p => p.Value.ExpiresAt <= DateTimeOffset.UtcNow).Select(p => p.Key).ToArray()) phoneDockerReviews.Remove(expired);
      phoneDockerReviews.TryGetValue(device.Id, out review);
    }
    if (review is not null)
    {
      var names = review.Draft.Environment.Split('\n').Where(l => l.Contains('=')).Select(l => l[..l.IndexOf('=')]);
      var body = review.Draft.Name + " · " + review.Draft.Directory + "\n" + ServerText.Mask(review.Draft.Compose) + "\nEnvironment names: " + string.Join(", ", names);
      rows.Insert(0, new JsonObject { ["id"] = "review:" + review.Token, ["title"] = "Review " + review.Action, ["body"] = body.Length > 16000 ? body[..16000] + "\n[Configuration preview excerpt.]" : body, ["bodyStyle"] = "code", ["actions"] = new JsonArray(PanelAction("deploy-reviewed", "Run reviewed " + review.Action), PanelAction("cancel-review", "Cancel review")) });
    }
    lock (phoneQualityResults) if (phoneQualityResults.TryGetValue(device.Id + ":docker", out var outcome)) rows.Insert(0, new JsonObject { ["id"] = "outcome", ["title"] = "App action result", ["body"] = outcome[..Math.Min(16000, outcome.Length)], ["bodyStyle"] = "code" });
    return Panel("Docker Apps", rows);
  }, async (device, request, ct) =>
  {
    await RequirePhoneCurrentAsync(device, ct); var action = PanelText(request, "action")!; var id = PanelText(request, "id")!; var caller = PhoneServerCaller(device);
    if (action is "cancel-review" or "deploy-reviewed")
    {
      PhoneDockerReview review; lock (phoneDockerReviews) review = phoneDockerReviews.GetValueOrDefault(device.Id) ?? throw new PhoneRefusal("unavailable", "Preview the app configuration again.");
      if (review.ExpiresAt <= DateTimeOffset.UtcNow || id != "review:" + review.Token) throw new PhoneRefusal("unauthorized", "This review expired or belongs to another app.");
      if (action == "cancel-review") { lock (phoneDockerReviews) phoneDockerReviews.Remove(device.Id); return; }
      var service = Servers as ServerService ?? throw new PhoneRefusal("unavailable", "The Docker Apps owner is not ready.");
      var result = await service.DeployAppAsync(review.Server, review.Draft, review.Action, caller, ct);
      lock (phoneQualityResults) phoneQualityResults[device.Id + ":docker"] = result.Output; lock (phoneDockerReviews) phoneDockerReviews.Remove(device.Id); return;
    }
    if (id.StartsWith("server:", StringComparison.Ordinal))
    {
      var serverId = id[7..]; var server = Servers.Get(serverId, caller); var service = Servers as ServerService ?? throw new PhoneRefusal("unavailable", "The Docker Apps owner is not ready."); var fields = PanelFields(request);
      string Required(string key) => fields.GetValueOrDefault(key) is { Length: > 0 } value ? value : throw new PhoneRefusal("bad-message", "Fill in " + key + ".");
      if (action == "read-config")
      {
        var draft = await service.ReadAppConfigurationAsync(serverId, Required("name"), Required("directory"), caller, ct);
        lock (phoneQualityResults) phoneQualityResults[device.Id + ":docker"] = draft.Name + " · " + draft.Directory + "\n" + ServerText.Mask(draft.Compose); return;
      }
      var operation = Required("operation"); var template = fields.GetValueOrDefault("template") ?? "custom"; var name = Required("name"); var directory = Required("directory");
      DockerAppDraft proposed;
      if (template != "custom")
      {
        if (!int.TryParse(Required("port"), out var port)) throw new PhoneRefusal("bad-message", "Enter a numeric host port.");
        proposed = ServerService.FromTemplate(template, name, directory, port);
        if (!string.IsNullOrWhiteSpace(fields.GetValueOrDefault("compose"))) proposed = proposed with { Compose = fields["compose"] };
        if (!string.IsNullOrWhiteSpace(fields.GetValueOrDefault("environment"))) proposed = proposed with { Environment = fields["environment"] };
      }
      else proposed = new(name, directory, Required("compose"), fields.GetValueOrDefault("environment") ?? "");
      proposed = proposed with { Repository = string.IsNullOrWhiteSpace(fields.GetValueOrDefault("repository")) ? null : fields["repository"], Branch = string.IsNullOrWhiteSpace(fields.GetValueOrDefault("branch")) ? null : fields["branch"] };
      if (operation is not ("create" or "update" or "validate" or "pull" or "start" or "stop" or "restart" or "remove")) throw new PhoneRefusal("bad-message", "Choose a supported app action.");
      _ = service.PreviewApp(serverId, proposed, caller);
      lock (phoneDockerReviews) phoneDockerReviews[device.Id] = new(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24)), serverId, proposed, operation, DateTimeOffset.UtcNow.AddMinutes(10)); return;
    }
    var parts = id.Split(':', 2); if (parts.Length != 2) throw new PhoneRefusal("bad-message", "Choose a current server app.");
    if (action == "logs") { var output = await Servers.LogsAsync(parts[0], parts[1], 200, caller, ct); lock (phoneQualityResults) phoneQualityResults[device.Id + ":docker"] = output; }
    else await Servers.ControlAsync(parts[0], parts[1], action, caller, ct);
  });
  private static JsonObject[] DockerPhoneFields(SavedServer server) =>
  [PanelField("name", "App name", "my-app", true), PanelField("directory", "App folder", (server.Access.Folders.FirstOrDefault() ?? "").TrimEnd('/') + "/my-app", true),
   PanelField("operation", "Action", "create", true, ["create", "update", "validate", "pull", "start", "stop", "restart", "remove"]),
   PanelField("template", "Template", "custom", true, ServerService.AppCatalog.Select(t => t.Id).ToArray()), PanelField("port", "Host port", "8080"),
   PanelField("compose", "Compose configuration"), PanelField("environment", "Environment · KEY=value per line"), PanelField("repository", "Optional public HTTPS repository"), PanelField("branch", "Optional branch")];
}
