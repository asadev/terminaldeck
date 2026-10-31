using System.Net.WebSockets;
using System.Security.Cryptography;

namespace TerminalDeck.Core.Remote;

public enum RelayConnectionState { Connecting, Connected, Disconnected, Stopped }

public sealed class RelayHostClient : IDisposable
{
  private readonly Uri relay;
  private readonly byte[] hostSecret;
  private readonly NoiseIdentity identity;
  private readonly IRelayPhoneApplication application;
  private readonly Func<IRelaySocket> makeSocket;
  private readonly TimeProvider clock;
  private readonly IRelayMcpApplication? mcp;
  private int running;
  public event Action<RelayConnectionState>? StateChanged;

  public RelayHostClient(Uri relay, ReadOnlySpan<byte> hostSecret, NoiseIdentity identity,
    IRelayPhoneApplication application, Func<IRelaySocket>? makeSocket = null, TimeProvider? clock = null, IRelayMcpApplication? mcp = null)
  {
    RelayEndpoint.Validate(relay);
    if (hostSecret.Length != 32) throw new ArgumentException("A host secret must be 32 bytes.");
    this.relay = relay;
    this.hostSecret = hostSecret.ToArray();
    this.identity = identity;
    this.application = application;
    this.makeSocket = makeSocket ?? (() => new RelayWebSocket());
    this.clock = clock ?? TimeProvider.System; this.mcp = mcp;
  }

  public static RelayHostClient ForRendezvous(Uri relay, RendezvousIdentity identity, IRelayPhoneApplication application) =>
    new(relay, identity.HostSecret, identity.Keys, application);

  public async Task RunAsync(CancellationToken cancellationToken)
  {
    if (Interlocked.Exchange(ref running, 1) != 0) throw new InvalidOperationException("This relay client is already running.");
    var attempt = 0;
    try
    {
      while (!cancellationToken.IsCancellationRequested)
      {
        await using (var socket = makeSocket())
        await using (var connection = new RelayHostConnection(identity, application, mcp, clock))
        {
          try
          {
            StateChanged?.Invoke(RelayConnectionState.Connecting);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(15));
            await socket.ConnectAsync(RelayEndpoint.Host(relay), hostSecret, deadline.Token).ConfigureAwait(false);
            StateChanged?.Invoke(RelayConnectionState.Connected);
            await connection.RunAsync(socket, cancellationToken).ConfigureAwait(false);
          }
          catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
          catch (Exception ex) when (ex is WebSocketException or IOException or ProtocolException or OperationCanceledException)
          { /* Public status deliberately contains no transport headers or secrets. */ }
        }
        StateChanged?.Invoke(RelayConnectionState.Disconnected);
        var delay = TimeSpan.FromMilliseconds(Math.Min(30000, 500 * Math.Pow(2, Math.Min(attempt++, 6))));
        await Task.Delay(delay, clock, cancellationToken).ConfigureAwait(false);
      }
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    finally
    {
      Interlocked.Exchange(ref running, 0);
      StateChanged?.Invoke(RelayConnectionState.Stopped);
    }
  }

  public void Dispose()
  {
    if (Volatile.Read(ref running) != 0) throw new InvalidOperationException("Stop the relay client before disposing it.");
    CryptographicOperations.ZeroMemory(hostSecret);
  }
}
