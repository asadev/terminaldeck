using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

public sealed class PhoneWorkspaceComposite(params IPhoneHostWorkspace[] workspaces) : IPhoneHostWorkspace, IDisposable
{
  public void Bind(Func<string, JsonObject, CancellationToken, ValueTask> publish, Func<string, ApprovedDevice?> current) { foreach (var workspace in workspaces) workspace.Bind(publish, current); }
  public async ValueTask DisconnectedAsync(string channel) { foreach (var workspace in workspaces) await workspace.DisconnectedAsync(channel); }
  public void Dispose() { foreach (var workspace in workspaces.OfType<IDisposable>()) workspace.Dispose(); }
  public IReadOnlyList<string> Capabilities => workspaces.SelectMany(w => w.Capabilities).Distinct().ToArray();
  public bool Handles(string type) => workspaces.Any(w => w.Handles(type));
  public bool Permits(PhoneAccess access, string type) => workspaces.Any(w => w.Handles(type) && w.Permits(access, type));
  public ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    var workspace = workspaces.FirstOrDefault(w => w is IPhoneMessageWorkspace selective ? selective.Handles(type, message) : w is PhoneConnectedFeatures connected ? connected.Handles(type, message) : w.Handles(type));
    if (workspace is null) throw new PhoneRefusal("unavailable", "This remote page is not available.");
    if (!workspace.Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "This action needs more device access.");
    return workspace.HandleAsync(channel, device, type, message, rid, ct);
  }
}
