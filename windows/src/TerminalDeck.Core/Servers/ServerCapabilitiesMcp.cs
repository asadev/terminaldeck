using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Servers;

public sealed class ServerCapabilitiesMcp(IServers servers)
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  public static IReadOnlyList<McpToolSpec> Specs { get; } = Build();
  public IReadOnlyList<ServerToolContribution> Contributions() => Specs.Select(spec => new ServerToolContribution(spec, (context, args, ct) => CallAsync(spec.Id, context, args, ct))).ToArray();
  public bool Preflight(McpGrant grant, McpToolSpec spec, JsonElement args)
  {
    if (!grant.Tiers.Contains(spec.Tier) || !Specs.Any(s => s.Id == spec.Id) || grant.DeviceId is not null || !args.TryGetProperty("serverId", out var value) || value.ValueKind != JsonValueKind.String || value.GetString() is not { } id || !grant.Has("servers", id)) return false;
    try
    {
      var row = servers.Get(id, ServersMcp.Caller(grant));
      if (spec.Tier != McpTier.Read) ServerValidation.CanChange(row, ServersMcp.Caller(grant));
      return true;
    }
    catch (ServerRefusal) { return false; }
  }
  public async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    var spec = Specs.Single(s => s.Id == tool); McpSchema.Validate(spec.InputSchema, args);
    if (!context.Grant.Tiers.Contains(spec.Tier) || !Preflight(context.Grant, spec, args)) throw new McpRefusal("This server capability is outside the caller's current access.");
    if (spec.Tier != McpTier.Read && context.Grant.PermissionMode == AiPermissionMode.Plan) throw new McpRefusal("Planning mode cannot set up a server coding AI.");
    await context.EnsureCurrentAsync(ct);
    var caller = ServersMcp.Caller(context.Grant) with { EnsureCurrent = context.EnsureCurrentAsync };
    var id = args.GetProperty("serverId").GetString()!;
    object result;
    switch (tool)
    {
      case "servers.coding_ais": result = new { rows = await servers.CodingAisAsync(id, caller, ct), signin = (servers as ServerService)?.SigninAttempts?.State(id) }; break;
      case "servers.coding_ai":
        var receipt = await servers.ChangeCodingAiAsync(id, args.GetProperty("provider").GetString()!, args.GetProperty("action").GetString()!, caller, ct);
        if (receipt.SessionId is { } session) context.NoteSessionStarted(session);
        result = receipt; break;
      case "servers.websites": result = new { rows = await servers.WebsitesAsync(id, caller, ct) }; break;
      case "servers.website": result = await servers.WebsiteAsync(id, args.GetProperty("siteId").GetString()!, caller, ct); break;
      default: throw new McpRefusal("Choose a supported server capability.");
    }
    await context.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(result, Json);
  }
  private static IReadOnlyList<McpToolSpec> Build()
  {
    object Text(int max) => new { type = "string", minLength = 1, maxLength = max };
    object Choice(params string[] values) => new Dictionary<string, object> { ["type"] = "string", ["enum"] = values };
    McpToolSpec Spec(string id, McpTier tier, Dictionary<string, object> extra, params string[] required)
    {
      extra["serverId"] = Text(32);
      return new(id, id.Replace('.', '_'), tier, JsonSerializer.SerializeToElement(new { type = "object", properties = extra, required = new[] { "serverId" }.Concat(required).ToArray(), additionalProperties = false }));
    }
    return [Spec("servers.coding_ais", McpTier.Read, []), Spec("servers.coding_ai", McpTier.Alter, new() { ["provider"] = Choice("claude", "codex", "gemini"), ["action"] = Choice("install", "signin", "signout", "remove") }, "provider", "action"), Spec("servers.websites", McpTier.Read, []), Spec("servers.website", McpTier.Read, new() { ["siteId"] = Text(258) }, "siteId")];
  }
}
