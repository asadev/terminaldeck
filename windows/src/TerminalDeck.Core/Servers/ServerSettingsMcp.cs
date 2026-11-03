using System.Text.Json;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Mcp;
namespace TerminalDeck.Core.Servers;

public sealed class ServerSettingsMcp(IServers servers)
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [new("servers.ssh_aliases", "servers_ssh_aliases", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", additionalProperties = false, properties = new { } })),
   new("servers.settings", "servers_settings", McpTier.Read, Schema(false)),
   new("servers.settings_change", "servers_settings_change", McpTier.Alter, Schema(true))];
  private static JsonElement Schema(bool change) => JsonSerializer.SerializeToElement(change ? (object)new { type = "object", additionalProperties = false, required = new[] { "serverId", "do" }, properties = new { serverId = new { type = "string", maxLength = 32 }, @do = new { type = "string", @enum = new[] { "save", "setup", "remove", "alerts", "test-alerts", "terminal" } }, patch = new { type = "object" }, alerts = new { type = "object" }, folder = new { type = "string", maxLength = 4096 } } } : new { type = "object", additionalProperties = false, required = new[] { "serverId" }, properties = new { serverId = new { type = "string", maxLength = 32 } } });
  public void Register(McpDoor door)
  {
    foreach (var spec in Specs) door.Register(spec.Id, (context, args, ct) => CallAsync(spec.Id, context, args, ct));
  }
  public async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    var spec = Specs.Single(s => s.Id == tool); McpSchema.Validate(spec.InputSchema, args);
    if (!context.Grant.Tiers.Contains(spec.Tier)) throw new McpRefusal("This server settings action needs its granted tier.");
    if (context.Grant.DeviceId is not null || !context.Grant.Attended || !context.Grant.OwnerApplication && !context.Grant.ServerManagement) throw new McpRefusal("Server settings need the owner on this PC.");
    context.Require("settings", "servers"); await context.EnsureCurrentAsync(ct);
    var caller = ServersMcp.Caller(context.Grant) with { EnsureCurrent = context.EnsureCurrentAsync };
    if (tool == "servers.ssh_aliases") return JsonSerializer.SerializeToElement(await servers.SshAliasesAsync(caller, ct), Json);
    var id = args.GetProperty("serverId").GetString()!; context.Require("servers", id);
    if (tool == "servers.settings") return JsonSerializer.SerializeToElement(await servers.SettingsAsync(id, caller, ct), Json);
    if (args.GetRawText().Length > 32768) throw new McpRefusal("Server settings must fit within 32 KB.");
    switch (args.GetProperty("do").GetString())
    {
      case "save": await servers.SaveSettingsAsync(id, args.GetProperty("patch").Deserialize<ServerSettingsPatch>(Json) ?? throw new McpRefusal("Choose the settings to save."), caller, ct); break;
      case "setup": return JsonSerializer.SerializeToElement(await servers.HostingAsync(id, "setup", caller, ct), Json);
      case "remove": return JsonSerializer.SerializeToElement(await servers.HostingAsync(id, "remove", caller, ct), Json);
      case "alerts": await servers.SaveAlertsAsync(id, args.GetProperty("alerts").Deserialize<ServerAlertSettings>(Json) ?? throw new McpRefusal("Choose the alert settings."), caller, ct); break;
      case "test-alerts": return JsonSerializer.SerializeToElement(await servers.TestAlertsAsync(id, caller, ct), Json);
      case "terminal": return JsonSerializer.SerializeToElement(new { sessionId = await servers.OpenTerminalAtAsync(id, args.TryGetProperty("folder", out var folder) ? folder.GetString() : null, caller, ct) }, Json);
    }
    return JsonSerializer.SerializeToElement(new { saved = true });
  }
}
