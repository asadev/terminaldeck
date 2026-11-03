using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// App composition owns this before the Shell exists; attaching the real browser
// never changes the authenticated phone chain or shares another UI's ownership.
public sealed class PhoneDeferredWorkspace : IPhoneHostWorkspace, IDisposable
{
  private IPhoneHostWorkspace? target;
  private Func<string, JsonObject, CancellationToken, ValueTask>? publish;
  private Func<string, ApprovedDevice?>? current;
  public IReadOnlyList<string> Capabilities => Volatile.Read(ref target)?.Capabilities ?? [];
  public bool Handles(string type) => Volatile.Read(ref target)?.Handles(type) == true;
  public bool Permits(PhoneAccess access, string type) => Volatile.Read(ref target)?.Permits(access, type) == true;
  public void Attach(IPhoneHostWorkspace workspace)
  {
    if (publish is { } send && current is { } device) workspace.Bind(send, device);
    var old = Interlocked.Exchange(ref target, workspace); (old as IDisposable)?.Dispose();
  }
  public void Bind(Func<string, JsonObject, CancellationToken, ValueTask> publisher, Func<string, ApprovedDevice?> device)
  { publish = publisher; current = device; Volatile.Read(ref target)?.Bind(publisher, device); }
  public ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct) =>
    Volatile.Read(ref target)?.HandleAsync(channel, device, type, message, rid, ct) ?? throw new PhoneRefusal("unavailable", "This PC's browser is not ready yet.");
  public ValueTask DisconnectedAsync(string channel) => Volatile.Read(ref target)?.DisconnectedAsync(channel) ?? ValueTask.CompletedTask;
  public void Dispose() { var old = Interlocked.Exchange(ref target, null); (old as IDisposable)?.Dispose(); }
}
