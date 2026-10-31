using System.Collections.Concurrent;
using System.Text.Json;

namespace TerminalDeck.Core.Mcp;

public sealed record McpCallerPolicy(string CallerId, string? SessionId, string? SeatId, AiPermissionMode Mode,
  string[] Tools, McpTier[] Tiers, string[] Resources, bool Relay = false, bool ServerManagement = false, IMcpCallerScope? Scope = null);
public sealed record McpActionRecord(DateTimeOffset At, string CallerId, string? SessionId, string? SeatId, string Tool, string Target, AiPermissionMode Mode);

// The client presents the tool name, schema and arguments in its native
// permission flow before invoking MCP. A provisioned key is that client's
// identity, never an owner token or a request-supplied permission mode.
public sealed class McpCallerAuthority : IMcpPermissionBroker
{
  private sealed record Entry(McpCallerPolicy Policy, McpRegistration Registration, Func<McpCallerPolicy, bool> Current);
  private readonly ConcurrentDictionary<string, Entry> callers = new();
  public event Action<McpActionRecord>? Authorized;

  public McpRegistration Provision(McpDoor door, McpCallerPolicy policy, Func<McpCallerPolicy, bool> current)
  {
    if (string.IsNullOrWhiteSpace(policy.CallerId) || policy.CallerId.Length > 128 || policy.CallerId.Any(char.IsControl) ||
      !Enum.IsDefined(policy.Mode) || policy.Resources.Length == 0 || policy.Resources.Contains("*") ||
      policy.Resources.Any(r => !r.Contains(':') || r.Any(char.IsControl)) ||
      policy.SessionId is { } session && !policy.Resources.Contains("sessions:" + session))
      throw new ArgumentException("Choose a caller, its permission mode and exact granted items.");
    var saved = policy with { Tools = [.. policy.Tools], Tiers = [.. policy.Tiers], Resources = [.. policy.Resources] };
    if (!current(saved)) throw new McpRefusal("This caller's session or permission is no longer current.");
    if (callers.ContainsKey(saved.CallerId)) throw new McpRefusal("Revoke this caller's old connection before replacing it.");
    var registration = door.RegisterCaller(new(saved.CallerId, saved.SessionId, null, true, saved.Mode,
      saved.Tools, saved.Tiers, saved.Resources, DateTimeOffset.UtcNow.AddHours(8), OwnerApplication: false, AllowRelay: saved.Relay, SeatId: saved.SeatId, ServerManagement: saved.ServerManagement, Scope: saved.Scope),
      (_, _, _, _, _) => ValueTask.FromResult(callers.TryGetValue(saved.CallerId, out var entry) && entry.Current(entry.Policy)));
    if (!callers.TryAdd(saved.CallerId, new(saved, registration, current))) { door.Revoke(registration.Id); throw new McpRefusal("This caller already has a connection."); }
    return registration;
  }
  public bool IsCurrent(string callerId) => callers.TryGetValue(callerId, out var entry) && entry.Current(entry.Policy);
  // The live registration of a current caller, so a reconnecting bridge can be
  // handed the same key instead of a replacement that drops its MCP session.
  public McpRegistration? Current(string callerId) => callers.TryGetValue(callerId, out var entry) && entry.Current(entry.Policy) ? entry.Registration : null;
  public IReadOnlyList<McpCallerPolicy> List() => callers.Values.Select(e => e.Policy with
  { Tools = [.. e.Policy.Tools], Tiers = [.. e.Policy.Tiers], Resources = [.. e.Policy.Resources] }).ToArray();
  public void Revoke(McpDoor door, string callerId)
  { if (callers.TryRemove(callerId, out var entry)) door.Revoke(entry.Registration.Id); }
  public void RevokeAll(McpDoor door) { foreach (var id in callers.Keys) Revoke(door, id); }

  public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (!callers.TryGetValue(request.CallerId, out var entry) || !entry.Current(entry.Policy) || entry.Policy.Mode != request.Mode)
      throw new McpRefusal("This AI connection is no longer current. Reconnect it in Settings.");
    if (request.Mode == AiPermissionMode.Plan) throw new McpRefusal("This AI is in planning mode and cannot change app data.");
    // Ask/Auto/AcceptEdits are enforced by the calling AI before the tool call.
    // Bypass skips that question, while the door still enforces every live grant.
    Authorized?.Invoke(new(DateTimeOffset.UtcNow, request.CallerId, entry.Policy.SessionId, entry.Policy.SeatId,
      request.Tool, request.Description, request.Mode));
    return ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true));
  }
  public static string Describe(string tool, JsonElement arguments)
  {
    var target = new List<string>();
    foreach (var key in new[] { "sessionId", "window", "action", "do", "control", "accountId", "account", "projectId", "agentId", "profile" })
      if (arguments.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String)
        target.Add(key + "=" + new string(value.GetString()!.Where(c => !char.IsControl(c)).Take(160).ToArray()));
    return tool + (target.Count == 0 ? "" : " · " + string.Join(", ", target));
  }
}
