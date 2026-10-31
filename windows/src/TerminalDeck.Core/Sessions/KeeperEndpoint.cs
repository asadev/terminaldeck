using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Sessions;

// Only a same-user, root-scoped platform transport may expose this endpoint.
public sealed class KeeperEndpoint(SessionKeeper keeper, ReadOnlyMemory<byte> secret, string version, Func<CancellationToken, ValueTask<bool>>? shutdownIdle = null,
  Func<CancellationToken, ValueTask<int>>? prepareUpdate = null)
{
  private readonly byte[] expected = secret.Length >= 32 ? secret.ToArray() : throw new ArgumentException("The keeper needs a private credential.");

  public async ValueTask<KeeperResponse> HandleAsync(KeeperRequest request, CancellationToken cancellationToken = default)
  {
    var supplied = Encoding.UTF8.GetBytes(request.Secret);
    if (!CryptographicOperations.FixedTimeEquals(supplied, expected)) throw new UnauthorizedAccessException("The private keeper could not be authenticated.");
    if (request.ProtocolVersion != KeeperWire.Version) throw new InvalidOperationException("The running keeper uses a different version. Its sessions were left running.");
    if (request.Operation == "hello") return new(Hello: new(KeeperWire.Version, version, keeper.Instance));
    if (request.Operation == "list") return new(Sessions: keeper.List());
    if (request.Operation == "snapshot")
    {
      await using var attach = await keeper.AttachAsync(Id(request), cancellationToken);
      return new(Snapshot: attach.Snapshot);
    }
    if (request.Instance != keeper.Instance) throw new InvalidOperationException("The keeper restarted. Reconnect before changing a session.");
    switch (request.Operation)
    {
      case "shutdown-idle":
        if (shutdownIdle is null || !await shutdownIdle(cancellationToken)) throw new InvalidOperationException("The keeper still owns work or does not support idle shutdown.");
        return new(Success: true);
      case "prepare-update":
        // The supervisor saves every session for the next version, retires its
        // workers and exits, so Windows can replace the package files.
        if (prepareUpdate is null) throw new InvalidOperationException("This keeper cannot hand over its sessions for an update.");
        await prepareUpdate(cancellationToken);
        return new(Success: true);
      case "create": return new(Session: await keeper.CreateAsync(request.Launch ?? throw new ArgumentException("Choose a session to create."), cancellationToken));
      case "account-rollback": return new(Session: await keeper.RollbackAccountAsync(request.Launch ?? throw new ArgumentException("Choose the original account."), request.Transaction ?? "", cancellationToken));
      case "account": return new(Session: await keeper.SwitchAccountAsync(request.Launch ?? throw new ArgumentException("Choose an account."), request.Revision ?? -1, request.Transaction ?? "", cancellationToken));
      case "write": await keeper.WriteAsync(Id(request), keeper.Instance, request.Bytes ?? throw new ArgumentException("Choose input to send."), cancellationToken); break;
      case "resize": await keeper.ResizeAsync(Id(request), keeper.Instance, new TerminalSize(request.Cols ?? 0, request.Rows ?? 0), cancellationToken); break;
      case "rename": await keeper.RenameAsync(Id(request), request.Title ?? throw new ArgumentException("Choose a title."), cancellationToken); break;
      case "remove": await keeper.StopAsync(Id(request), keeper.Instance, cancellationToken); break;
      default: throw new InvalidOperationException("This keeper action is not available yet.");
    }
    return new(Success: true);
  }

  public async ValueTask<SessionAttachment> WatchAsync(KeeperRequest request, CancellationToken cancellationToken = default)
  {
    if (request.Operation != "watch") throw new ArgumentException("Choose watch to attach a session.");
    // Authenticate with the same path as ordinary requests before opening a stream.
    await HandleAsync(new KeeperRequest { Secret = request.Secret, ProtocolVersion = request.ProtocolVersion, Operation = "hello" }, cancellationToken);
    if (request.Instance != keeper.Instance) throw new InvalidOperationException("The keeper restarted. Reconnect before attaching.");
    return await keeper.AttachAsync(Id(request), cancellationToken);
  }
  private static string Id(KeeperRequest request) => request.Id ?? throw new ArgumentException("Choose a session.");
}
