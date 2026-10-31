using System.Collections.Immutable;
using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Servers;

public sealed record ServerToolContribution(McpToolSpec Spec, McpToolHandler Handler);
public sealed class ServersMcp(IServers servers, IServerKeyPicker? keyPicker = null, TimeProvider? time = null)
{
  private sealed record KeyPick(string CallerId, string? SessionId, string Path, DateTimeOffset ExpiresAt);
  private readonly ConcurrentDictionary<string, KeyPick> keyPicks = new();
  private readonly ConcurrentDictionary<(string Caller, string? Session, string Server), DateTimeOffset> createdServers = new();
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private static readonly object Text = new { type = "string", maxLength = 4096 };
  private static readonly object Strings = new { type = "array", items = Text, maxItems = 100 };
  private static readonly object Boolean = new { type = "boolean" };
  public static IReadOnlyList<McpToolSpec> Specs { get; } = MakeSpecs();
  public IReadOnlyList<ServerToolContribution> Contributions() => Specs.Select(s => new ServerToolContribution(s,
    (context, args, ct) => CallAsync(s.Id, context, args, ct))).ToArray();
  public void Register(McpDoor door)
  {
    var catalogue = McpCatalogue.Load().ToDictionary(s => s.Id);
    if (Specs.Any(s => !catalogue.TryGetValue(s.Id, out var installed) || installed.Tier != s.Tier || !JsonElement.DeepEquals(installed.InputSchema, s.InputSchema)))
      throw new InvalidOperationException("Install ServersMcp.Specs in the central catalogue before connecting the Servers handlers.");
    foreach (var c in Contributions()) door.Register(c.Spec.Id, c.Handler);
  }
  public static ServerCaller Caller(McpGrant grant) => new(grant.CallerId, grant.OwnerApplication,
    LocalSession: grant.SessionId is not null && grant.DeviceId is null, PairedDevice: grant.DeviceId is not null, ManageServers: grant.ServerManagement && Has(grant, "settings:servers"));
  // The integration lane must run this from the door's live-permission callback,
  // before the permission broker, so Look only refuses without asking the person.
  public bool Preflight(McpGrant grant, McpToolSpec spec, JsonElement args)
  {
    if (!Specs.Any(s => s.Id == spec.Id) || grant.DeviceId is not null) return false;
    var caller = Caller(grant);
    if (spec.Id is "servers.add" or "servers.pick_key") return (grant.OwnerApplication || caller.ManageServers) && Has(grant, "settings:servers");
    if (spec.Id is "servers.rename" or "servers.access" or "servers.remove" or "servers.trust_host" or "servers.host_key")
      if (!grant.OwnerApplication && !caller.ManageServers) return false;
    var id = String(args, "serverId") ?? String(args, "target");
    if (id is null) return spec.Id is "servers.look" or "docker.targets";
    if (!HasServer(grant, id)) return false;
    // Forgetting a server removes its saved row. The final live caller check
    // still checks identity and scope; the service checks the row before effects.
    if (spec.Id == "servers.remove") return true;
    try
    {
      var server = servers.Get(id, caller);
      if (spec.Tier != McpTier.Read && spec.Id is not ("servers.rename" or "servers.access" or "servers.remove" or "servers.trust_host") &&
        !(spec.Id == "servers.files_change" && String(args, "do") == "download")) ServerValidation.CanChange(server, caller);
      if (spec.Id == "servers.control" && !caller.Owner && !caller.LocalSession && !grant.Tiers.Contains(McpTier.Alter)) return false;
      return true;
    }
    catch (ServerRefusal) { return false; }
  }
  private bool HasServer(McpGrant grant, string id) => Has(grant, "servers:" + id) ||
    grant.ServerManagement && Has(grant, "settings:servers") && createdServers.TryGetValue((grant.CallerId, grant.SessionId, id), out var expiry) && expiry > clock.GetUtcNow();
  // Same matching as every other tool (exact, kind-wide, "*", or the caller's live scope: Hoot's covers servers).
  private static bool Has(McpGrant grant, string resource) => resource.IndexOf(':') is var at and > 0 && grant.Has(resource[..at], resource[(at + 1)..]);
  public async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    var spec = Specs.Single(s => s.Id == tool); McpSchema.Validate(spec.InputSchema, args);
    if (!context.Grant.Tiers.Contains(spec.Tier) || !Preflight(context.Grant, spec, args)) throw new McpRefusal("This server action is outside the caller's current access.");
    if (spec.Tier != McpTier.Read && context.Grant.PermissionMode == AiPermissionMode.Plan) throw new McpRefusal("This AI is in planning mode and cannot change a server.");
    await context.EnsureCurrentAsync(ct); var caller = Caller(context.Grant) with { EnsureCurrent = context.EnsureCurrentAsync };
    string Required(string key) => String(args, key) is { Length: > 0 } s ? s : throw new McpRefusal("Choose " + key + ".");
    var id = String(args, "serverId") ?? String(args, "target");
    if (tool is "servers.look" or "docker.targets" && id is null)
      return Value(new { servers = servers.List(caller).Where(s => HasServer(context.Grant, s.Id) && (String(args, "projectId") is not { } p || s.ProjectId == p)) });
    if (tool == "servers.pick_key")
    {
      if (keyPicker is null) throw new McpRefusal("Open this app's server page to choose a key file.");
      var path = await keyPicker.PickAsync(ct);
      await context.EnsureCurrentAsync(ct);
      if (path is null) return Value(new { cancelled = true });
      foreach (var old in keyPicks.Where(p => p.Value.ExpiresAt <= clock.GetUtcNow())) keyPicks.TryRemove(old.Key, out _);
      if (keyPicks.Count >= 32) throw new McpRefusal("Finish an earlier key selection before choosing another file.");
      var receipt = Guid.NewGuid().ToString("N");
      keyPicks[receipt] = new(context.Grant.CallerId, context.Grant.SessionId, path, clock.GetUtcNow().AddMinutes(5));
      return Value(new { keyReceipt = receipt, fileName = Path.GetFileName(path) });
    }
    if (tool == "servers.add")
    {
      var bytes = Encoding.UTF8.GetBytes(String(args, "password") ?? "");
      try
      {
        string? key = null;
        if (String(args, "keyReceipt") is { } receipt)
        {
          if (!keyPicks.TryGetValue(receipt, out var pick) || pick.CallerId != context.Grant.CallerId || pick.SessionId != context.Grant.SessionId || pick.ExpiresAt <= clock.GetUtcNow() || !keyPicks.TryRemove(receipt, out _))
            throw new McpRefusal("Ask the person to choose the key file again.");
          key = pick.Path;
        }
        var saved = await servers.AddAsync(new(Required("name"), Required("host"), Number(args, "port", 22), Required("user"), key is null ? ServerAuthentication.Password : ServerAuthentication.Key), key, bytes, ct, caller);
        await context.EnsureCurrentAsync(ct);
        // Scope only the server this connection just created, until its normal
        // provisioned grant is refreshed. This never grants every saved server.
        foreach (var old in createdServers.Where(p => p.Value <= clock.GetUtcNow())) createdServers.TryRemove(old.Key, out _);
        if (context.Grant.ServerManagement) createdServers[(context.Grant.CallerId, context.Grant.SessionId, saved.Id)] = context.Grant.ExpiresAt;
        return Value(saved);
      }
      finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
    }
    if (id is null) throw new McpRefusal("Choose a server.");
    if (!HasServer(context.Grant, id)) throw new McpRefusal("That server is outside this caller's permission.");
    switch (tool)
    {
      case "servers.look": return Value(new { server = servers.Get(id, caller), cards = await servers.AppsAsync(id, caller, ct) });
      case "servers.health":
        var health = await servers.HealthAsync(id, caller, ct); await context.EnsureCurrentAsync(ct); return Value(health);
      case "servers.test": return Value(new { message = await servers.TestAsync(id, caller, ct) });
      case "servers.host_key": return Value(new { publicKey = await servers.ScanHostKeyAsync(id, caller, ct), verified = false });
      case "servers.trust_host": await servers.TrustHostKeyAsync(id, Required("publicKey"), caller, ct); break;
      case "servers.access":
        await servers.SetAccessAsync(id, new(args.GetProperty("lookOnly").GetBoolean(),
          args.GetProperty("folders").EnumerateArray().Select(x => x.GetString()!).ToImmutableArray(),
          args.GetProperty("aiApps").EnumerateArray().Select(x => x.GetString()!).ToImmutableArray()), caller, ct); break;
      case "servers.rename": await servers.RenameAsync(id, Required("name"), caller, ct); break;
      case "servers.remove": await servers.RemoveAsync(id, Required("confirmName"), caller, ct); break;
      case "servers.files_list":
      {
        var page = await servers.FilesPageAsync(id, String(args, "path") ?? servers.Get(id, caller).Access.Folders.FirstOrDefault() ?? "/", Number(args, "offset", 0), caller, ct);
        return Value(page);
      }
      case "servers.files_read": return Value(await servers.ReadAsync(id, Required("path"), caller, ct));
      case "servers.files_change":
      {
        var op = Required("do"); var path = Required("path");
        if (op is "upload" or "download")
        {
          var local = Required("localPath"); context.Require("folders", Path.GetDirectoryName(local) ?? local);
          if (op == "download") await servers.DownloadAsync(id, path, local, caller, ct);
          else
          {
            if (!File.Exists(local) || new FileInfo(local).Length > ServerFilesScript.TransferLimit) throw new McpRefusal("Choose a local file up to 8 MB.");
            await servers.UploadAsync(id, path, await File.ReadAllBytesAsync(local, ct), caller, ct);
          }
        }
        else await servers.ChangeFileAsync(id, path, op, String(args, "name"), String(args, "confirmName"), caller, ct);
        break;
      }
      case "docker.containers.list": return Value(new { containers = await servers.AppsAsync(id, caller, ct) });
      case "servers.logs": case "docker.logs": case "docker.logs.open":
        return Value(new { text = await servers.LogsAsync(id, String(args, "cardId") ?? Required("id"), Number(args, tool == "servers.logs" ? "lines" : "tail", 200), caller, ct) });
      case "servers.control": await servers.ControlAsync(id, Required("cardId"), Required("action"), caller, ct); break;
      case "docker.containers.start": case "docker.containers.stop": case "docker.containers.restart":
        await servers.ControlAsync(id, Required("id"), tool.Split('.').Last(), caller, ct); break;
      case "servers.terminal":
        var sessionId = await servers.OpenTerminalAsync(id, caller, ct); context.NoteSessionStarted(sessionId); return Value(new { sessionId });
      default: throw new McpRefusal("That server tool is unavailable.");
    }
    await context.EnsureCurrentAsync(ct); return Value(new { ok = true });
  }
  private static JsonElement Value(object value) => JsonSerializer.SerializeToElement(value, Json);
  private static string? String(JsonElement args, string key) => args.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
  private static int Number(JsonElement args, string key, int fallback) => args.TryGetProperty(key, out var value) ? value.GetInt32() : fallback;
  private static IReadOnlyList<McpToolSpec> MakeSpecs()
  {
    var specs = new List<McpToolSpec>();
    object Choice(params string[] values) => new Dictionary<string, object> { ["type"] = "string", ["enum"] = values };
    object Integer(int min, int max) => new { type = "integer", minimum = min, maximum = max };
    void Add(string id, McpTier tier, Dictionary<string, object> fields, params string[] required) => specs.Add(new(id, id.Replace('.', '_'), tier,
      Value(new { type = "object", properties = fields, required, additionalProperties = false })));
    Dictionary<string, object> Server(params (string Key, object Value)[] fields) => new Dictionary<string, object>(fields.Select(f => KeyValuePair.Create(f.Key, f.Value))) { ["serverId"] = Text };
    Dictionary<string, object> Target(params (string Key, object Value)[] fields) => new Dictionary<string, object>(fields.Select(f => KeyValuePair.Create(f.Key, f.Value))) { ["target"] = Text };
    Add("servers.look", McpTier.Read, Server(("projectId", Text)));
    Add("servers.logs", McpTier.Read, Server(("cardId", Text), ("lines", Integer(1, 2000))), "serverId", "cardId");
    Add("servers.control", McpTier.Act, Server(("cardId", Text), ("action", Choice("start", "stop", "restart"))), "serverId", "cardId", "action");
    Add("servers.files_list", McpTier.Read, Server(("path", Text), ("offset", new { type = "integer", minimum = 0, maximum = int.MaxValue - 1000 })), "serverId");
    Add("servers.files_read", McpTier.Read, Server(("path", Text)), "serverId", "path");
    Add("servers.files_change", McpTier.Alter, Server(("path", Text), ("do", Choice("upload", "download", "rename", "delete")), ("name", Text), ("localPath", Text), ("confirmName", Text)), "serverId", "path", "do");
    Add("servers.pick_key", McpTier.Alter, []);
    Add("servers.add", McpTier.Alter, new() { ["name"] = Text, ["host"] = Text, ["port"] = Integer(1, 65535), ["user"] = Text, ["keyReceipt"] = Text, ["password"] = Text }, "name", "host", "user");
    Add("servers.access", McpTier.Alter, Server(("lookOnly", Boolean), ("folders", Strings), ("aiApps", Strings)), "serverId", "lookOnly", "folders", "aiApps");
    Add("servers.rename", McpTier.Alter, Server(("name", Text)), "serverId", "name");
    Add("servers.remove", McpTier.Alter, Server(("confirmName", Text)), "serverId", "confirmName");
    Add("servers.health", McpTier.Read, Server(), "serverId");
    Add("servers.test", McpTier.Read, Server(), "serverId");
    Add("servers.host_key", McpTier.Read, Server(), "serverId");
    Add("servers.trust_host", McpTier.Alter, Server(("publicKey", Text)), "serverId", "publicKey");
    Add("servers.terminal", McpTier.Alter, Server(), "serverId");
    Add("docker.targets", McpTier.Read, []);
    Add("docker.containers.list", McpTier.Read, Target(("all", Boolean)), "target");
    foreach (var suffix in new[] { "logs", "logs.open" }) Add("docker." + suffix, McpTier.Read, Target(("id", Text), ("tail", Integer(1, 2000))), "target", "id");
    foreach (var action in new[] { "start", "stop", "restart" }) Add("docker.containers." + action, McpTier.Alter, Target(("id", Text)), "target", "id");
    return specs;
  }
}
