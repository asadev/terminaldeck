using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Mcp;

public enum AiPermissionMode { Ask, Plan, Auto, AcceptEdits, Bypass }
public sealed record McpGrant(string CallerId, string? SessionId, string? DeviceId, bool Attended, AiPermissionMode PermissionMode,
  string[] Tools, McpTier[] Tiers, string[] Resources, DateTimeOffset ExpiresAt, bool OwnerApplication = false, bool AllowRelay = false, string? SeatId = null, bool ServerManagement = false,
  IMcpCallerScope? Scope = null)
{
  // Exact items, a kind-wide item ("origins:*"), and folder items that contain
  // the requested path in any Windows spelling, then the caller's live scope.
  public bool Has(string kind, string id)
  {
    if (Resources.Contains(kind + ":" + id) || Resources.Contains(kind + ":*") || Resources.Contains("*")) return true;
    if (kind == "folders" && id.Length > 0)
      foreach (var resource in Resources)
        if (resource.StartsWith("folders:", StringComparison.Ordinal) && McpCallerScopes.Within(resource[8..], id)) return true;
    return Scope?.Has(kind, id) == true;
  }
}
// A live grant for items that appear after the connection opened (a project's
// new sessions, tasks and agents). It may only answer for items it can check now.
public interface IMcpCallerScope
{
  bool Has(string kind, string id);
}
public sealed record McpPermissionRequest(string CallerId, string Tool, McpTier Tier, string ActionDigest, AiPermissionMode Mode, string Description = "");
public sealed record McpPermissionProof(Guid Id, string CallerId, string ActionDigest, DateTimeOffset ExpiresAt, bool Approved);

// This bridge uses the calling AI's existing permission flow/standing approval.
// It must not show a second app approval for an action the AI already authorized.
public interface IMcpPermissionBroker
{
  ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken cancellationToken);
}
public sealed class McpRegistration(Guid id, string token)
{
  public Guid Id { get; } = id;
  public string Token { get; } = token;
  public override string ToString() => "<MCP registration>";
}

public sealed class McpCallContext
{
  private readonly Func<CancellationToken, ValueTask> current;
  private readonly Action<string> noteStarted;
  public McpGrant Grant { get; }
  internal McpCallContext(McpGrant grant, Func<CancellationToken, ValueTask> current, Action<string> noteStarted)
  { Grant = grant; this.current = current; this.noteStarted = noteStarted; }
  public bool Has(string kind, string id) => Grant.Has(kind, id);
  public void Require(string kind, string id)
  {
    if (!Has(kind, id)) throw new McpRefusal("That item is outside this caller's permission.");
  }
  public ValueTask EnsureCurrentAsync(CancellationToken cancellationToken) => current(cancellationToken);
  public void NoteSessionStarted(string sessionId) => noteStarted(sessionId);
  internal void NoteStarted(string sessionId) => noteStarted(sessionId);
}

public delegate ValueTask<JsonElement> McpToolHandler(McpCallContext context, JsonElement arguments, CancellationToken cancellationToken);
public delegate ValueTask<bool> McpLivePermission(McpGrant grant, McpToolSpec tool, JsonElement arguments, McpTier tier, CancellationToken cancellationToken);

public sealed class McpDoor(IMcpPermissionBroker permission, TimeProvider? time = null, Func<McpToolSpec, McpToolHandler, McpToolHandler>? wrap = null,
  Action<McpGrant, McpToolSpec, JsonElement>? preflight = null)
{
  private sealed record Handler(McpToolSpec Spec, McpToolHandler Run);
  private sealed record Caller(byte[] Digest, McpGrant Grant, McpLivePermission Permitted, long Revision, CancellationTokenSource Lifetime);
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  private readonly object gate = new();
  private readonly Dictionary<string, Handler> tools = [];
  private readonly Dictionary<Guid, Caller> callers = [];
  private readonly Dictionary<string, string> startedBy = [];
  private readonly ConcurrentDictionary<Guid, DateTimeOffset> consumed = [];
  private readonly Dictionary<string, McpToolSpec> contracts = McpCatalogue.Load().ToDictionary(t => t.Id);

  public void Register(string id, McpToolHandler handler)
  {
    lock (gate)
    {
      if (!contracts.TryGetValue(id, out var spec)) throw new ArgumentException("This tool has no source contract.");
      if (tools.ContainsKey(spec.Id) || tools.ContainsKey(spec.Wire)) throw new InvalidOperationException("This MCP tool is already registered.");
      var entry = new Handler(spec, wrap?.Invoke(spec, handler) ?? handler); tools.Add(spec.Id, entry); tools.Add(spec.Wire, entry);
    }
  }
  public void Compose(string id, Func<McpToolHandler?, McpToolHandler> compose)
  {
    lock (gate)
    {
      if (!contracts.TryGetValue(id, out var spec)) throw new ArgumentException("This tool has no source contract.");
      tools.TryGetValue(id, out var previous);
      var handler = compose(previous?.Run);
      var entry = new Handler(spec, wrap?.Invoke(spec, handler) ?? handler);
      tools[spec.Id] = entry; tools[spec.Wire] = entry;
    }
  }
  public McpRegistration RegisterCaller(McpGrant grant, McpLivePermission permitted)
  {
    if (string.IsNullOrWhiteSpace(grant.CallerId) || grant.ExpiresAt <= clock.GetUtcNow()) throw new ArgumentException("Choose a current MCP caller.");
    var id = Guid.NewGuid(); var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
    lock (gate) callers.Add(id, new(SHA256.HashData(Encoding.UTF8.GetBytes(token)), Copy(grant), permitted, 1, new()));
    return new(id, token);
  }
  public void UpdateCaller(Guid id, McpGrant grant)
  {
    lock (gate)
    {
      var caller = callers[id];
      if (caller.Grant.CallerId != grant.CallerId || caller.Grant.SessionId != grant.SessionId || caller.Grant.DeviceId != grant.DeviceId)
        throw new ArgumentException("A caller identity cannot be replaced by a permission update.");
      callers[id] = caller with { Grant = Copy(grant), Revision = caller.Revision + 1 };
    }
  }
  public void Revoke(Guid id)
  {
    Caller? removed;
    lock (gate) { callers.Remove(id, out removed); }
    removed?.Lifetime.Cancel();
  }
  public bool AllowsRelay(string token)
  {
    try { var id = Authenticate(token); lock (gate) return RequireCaller(id).Grant.AllowRelay; }
    catch (McpRefusal) { return false; }
  }
  public Guid Authenticate(string token)
  {
    if (token.Length is < 32 or > 256) throw new McpRefusal("This MCP caller is not allowed in.");
    var hash = SHA256.HashData(Encoding.UTF8.GetBytes(token));
    lock (gate)
    {
      foreach (var (id, caller) in callers)
        if (CryptographicOperations.FixedTimeEquals(hash, caller.Digest) && caller.Grant.ExpiresAt > clock.GetUtcNow()) return id;
    }
    throw new McpRefusal("This MCP caller is not allowed in.");
  }
  public CancellationToken Lifetime(Guid id) { lock (gate) return RequireCaller(id).Lifetime.Token; }
  public IReadOnlyList<McpToolSpec> List(Guid id)
  {
    lock (gate)
    {
      var caller = RequireCaller(id);
      return tools.Values.Distinct().Select(t => t.Spec).Where(t => caller.Grant.Tools.Contains(t.Id) && caller.Grant.Tiers.Contains(t.Tier)).OrderBy(t => t.Id).ToArray();
    }
  }
  public async ValueTask<JsonElement> CallAsync(Guid id, string name, JsonElement arguments, CancellationToken cancellationToken = default)
  {
    Caller caller; Handler handler; bool owns;
    lock (gate)
    {
      caller = RequireCaller(id);
      if (!tools.TryGetValue(name, out var found) || !caller.Grant.Tools.Contains(found.Spec.Id)) throw new McpRefusal("That tool is not available to this caller.");
      handler = found;
      var session = arguments.ValueKind == JsonValueKind.Object && arguments.TryGetProperty("sessionId", out var sid) && sid.ValueKind == JsonValueKind.String ? sid.GetString() : null;
      owns = session is not null && (session == caller.Grant.SessionId || startedBy.GetValueOrDefault(session) == caller.Grant.CallerId);
    }
    McpSchema.Validate(handler.Spec.InputSchema, arguments);
    var tier = McpCatalogue.EffectiveTier(handler.Spec, arguments, owns);
    using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, caller.Lifetime.Token);
    var ct = linked.Token;
    async ValueTask Current(CancellationToken token)
    {
      token.ThrowIfCancellationRequested();
      lock (gate)
      {
        var current = RequireCaller(id);
        if (current.Revision != caller.Revision || !current.Grant.Tiers.Contains(tier)) throw new McpRefusal("This caller's permission changed. Ask again with the current permission.");
      }
      preflight?.Invoke(Copy(caller.Grant), handler.Spec, arguments);
      if (!await caller.Permitted(Copy(caller.Grant), handler.Spec, arguments, tier, token)) throw new McpRefusal("This action is outside the caller's current permission.");
      lock (gate) if (RequireCaller(id).Revision != caller.Revision) throw new McpRefusal("This caller's permission changed.");
      token.ThrowIfCancellationRequested();
    }
    await Current(ct);
    if (tier != McpTier.Read)
    {
      if (caller.Grant.PermissionMode == AiPermissionMode.Plan) throw new McpRefusal("This AI is in planning mode. Choose a mode that allows changes first.");
      if (tier == McpTier.Alter && !caller.Grant.Attended) throw new McpRefusal("This change needs the person present.");
      var digest = ActionDigest(caller.Grant.CallerId, handler.Spec.Id, arguments, tier);
      var proof = await permission.AuthorizeAsync(new(caller.Grant.CallerId, handler.Spec.Id, tier, digest, caller.Grant.PermissionMode, McpCallerAuthority.Describe(handler.Spec.Id, arguments)), ct);
      var now = clock.GetUtcNow();
      foreach (var old in consumed.Where(p => p.Value <= now)) consumed.TryRemove(old.Key, out _);
      if (!proof.Approved || proof.CallerId != caller.Grant.CallerId || proof.ActionDigest != digest || proof.ExpiresAt <= now || proof.ExpiresAt > now.AddMinutes(5) || consumed.Count >= 4096 || !consumed.TryAdd(proof.Id, proof.ExpiresAt))
        throw new McpRefusal("This exact action has not been approved by the calling AI's permission setting.");
      await Current(ct);
    }
    var context = new McpCallContext(Copy(caller.Grant), Current, session => { lock (gate) startedBy[session] = caller.Grant.CallerId; });
    var result = await handler.Run(context, arguments, ct);
    await Current(ct); // Revocation during a read must not release its private result.
    return result;
  }
  private Caller RequireCaller(Guid id) => callers.TryGetValue(id, out var caller) && caller.Grant.ExpiresAt > clock.GetUtcNow() && !caller.Lifetime.IsCancellationRequested
    ? caller : throw new McpRefusal("This MCP caller is no longer allowed in.");
  private static McpGrant Copy(McpGrant grant) => grant with { Tools = [.. grant.Tools], Tiers = [.. grant.Tiers], Resources = [.. grant.Resources] };
  public static string ActionDigest(string caller, string tool, JsonElement args, McpTier tier)
  {
    using var stream = new MemoryStream(); using (var writer = new Utf8JsonWriter(stream))
    {
      writer.WriteStartArray(); writer.WriteStringValue(caller); writer.WriteStringValue(tool); writer.WriteStringValue(tier.ToString()); Canonical(writer, args); writer.WriteEndArray();
    }
    return Convert.ToHexStringLower(SHA256.HashData(stream.ToArray()));
  }
  private static void Canonical(Utf8JsonWriter writer, JsonElement value)
  {
    if (value.ValueKind == JsonValueKind.Object)
    {
      writer.WriteStartObject(); foreach (var p in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal)) { writer.WritePropertyName(p.Name); Canonical(writer, p.Value); } writer.WriteEndObject();
    }
    else if (value.ValueKind == JsonValueKind.Array) { writer.WriteStartArray(); foreach (var item in value.EnumerateArray()) Canonical(writer, item); writer.WriteEndArray(); }
    else value.WriteTo(writer);
  }
}
