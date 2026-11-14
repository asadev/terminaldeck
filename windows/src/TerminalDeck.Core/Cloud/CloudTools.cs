using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Cloud;

/// Cloud's agent tools on Windows, slice 1: reads only. Signing in, signing out and anything that changes state stay
/// with the person's own presses on the Settings page; no tool can start a sign-in.
public static class CloudTools
{
  public static IReadOnlyList<McpToolSpec> Specs => [
    new("cloud.status", "cloud_status", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))
  ];

  public static void Register(CloudAccountClient account, McpDoor door) => door.Register("cloud.status", (_, _, _) => ValueTask.FromResult(Status(account.Snapshot)));

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
