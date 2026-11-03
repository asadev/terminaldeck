using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// One explicit dispatch contract shared by phone and computer callers. The
// provider must resolve the current session/project before touching its owner.
public sealed class PhoneOwnerFeatures(Func<ApprovedDevice, string, JsonElement, string?, CancellationToken, ValueTask<JsonObject>> owner) : IPhoneHostWorkspace
{
  private static readonly HashSet<string> Reads = ["controls.read", "settings.read", "logins.read", "github.read", "host.status", "dev.status", "routines", "routine.text"];
  private static readonly HashSet<string> Writes = ["controls.apply", "settings.apply", "logins.signin", "logins.signout", "github.connect", "github.cancel", "github.disconnect", "host.restart", "host.stop", "dev.start"];
  public IReadOnlyList<string> Capabilities => ["controls", "settings", "logins", "github", "host.control", "devserver", "routines"];
  public bool Handles(string type) => Reads.Contains(type) || Writes.Contains(type);
  public bool Permits(PhoneAccess access, string type) => access != PhoneAccess.Hoot && (Reads.Contains(type) || access == PhoneAccess.Full || access == PhoneAccess.Work && type is "dev.start");
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    if (!Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "This action needs Full control.");
    ct.ThrowIfCancellationRequested();
    var result = await owner(device, type, message, rid, ct);
    if (System.Text.Encoding.UTF8.GetByteCount(result.ToJsonString()) > PhoneWire.MaximumMessageBytes - 1024) throw new PhoneRefusal("unavailable", "This reading is too large for one phone message.");
    return [result];
  }
}
