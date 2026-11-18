using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

/// The account status reads freely. Profile and device edits use the same owners as Settings and ask through the
/// caller's existing permission flow. No tool starts a new account sign-in.
public static partial class CloudTools
{
  public static IReadOnlyList<McpToolSpec> Specs => [
    .. ProfileSpecs,
    new("cloud.status", "cloud_status", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))
  ];

  public static void Register(CloudAccountClient account, McpDoor door, Func<System.Text.Json.Nodes.JsonObject?>? sessions = null)
  {
    door.Register("cloud.status", (_, _, _) => ValueTask.FromResult(WithSessions(Status(account.Snapshot), sessions?.Invoke())));
    RegisterProfile(account, door);
  }

  /// Lane C: the sessions and chat histories line (counts only, read only), when the uploader runs.
  private static JsonElement WithSessions(JsonElement status, System.Text.Json.Nodes.JsonObject? sessions)
  {
    if (sessions is null) return status;
    var node = System.Text.Json.Nodes.JsonNode.Parse(status.GetRawText())!.AsObject();
    node["sessions"] = sessions.DeepClone();
    return JsonSerializer.SerializeToElement(node);
  }

  /// The same plain state the person sees. Never a token, a key or the protected record.
  public static JsonElement Status(CloudSnapshot snapshot) => JsonSerializer.SerializeToElement(new
  {
    phase = Phase(snapshot.Phase),
    account = snapshot.Phase is CloudPhase.SignedIn or CloudPhase.NotAllowed or CloudPhase.Paused ? snapshot.Email : null,
    cloudOpen = snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused,
    useCloud = snapshot.UseCloud,
    thisDevice = snapshot.ThisDeviceName,
    // Owner, 13 Nov: a device is its name, when it was added and when it was last seen. No code, id, key or version.
    devices = snapshot.DeviceRows.Select(d => new { name = d.Name, thisDevice = d.ThisDevice, added = d.Added?.ToString("O"), lastSeen = d.LastSeen?.ToString("O") }),
    problem = snapshot.Problem
  }, CloudWire.Json);

  public static string Phase(CloudPhase phase) => phase switch
  {
    CloudPhase.Dormant => "dormant",
    CloudPhase.SignedOut => "signedOut",
    CloudPhase.SigningIn => "signingIn",
    CloudPhase.SignedIn => "signedIn",
    CloudPhase.NotAllowed => "notAllowed",
    _ => "paused"
  };
}
