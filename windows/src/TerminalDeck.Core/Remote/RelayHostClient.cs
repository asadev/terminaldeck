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
  private readonly IRelayReceiverApplication? receiver;
  // stream step 2 (dc2), direct only (#27): a phone host offers every approved device ONE link, with TURN logins from
  // this relay's Worker (its own host secret) while the relay socket is open; no phone data crosses the relay itself.
  private readonly RelayTurnLogins? turn;
  private readonly LinkIceSource? ice;
  private readonly LinkSetup? link;
  private readonly object linkGate = new();
  private HashSet<string> linkEligible = [];
  private bool linkRefreshed;
  private int connected;
  private int running;
  private RelayHostConnection? current;
  /// stream step 2: a connection moved onto its link.
  public event Action<string>? LinkMoved;
  /// Whether a phone channel has moved onto its link (its video then goes on td.rt / td.rel).
  public bool OnLink(string channel) => Volatile.Read(ref current)?.LinkRoute(channel) is not null;
  /// A relay channel whose link has not moved yet: nothing for it may be sent until it has (direct only).
  public bool AwaitsLink(string channel) => Volatile.Read(ref current)?.AwaitsLink(channel) == true;
  /// A channel with a live direct link (moved or about to): the only kind that may watch a screen (contract §11.7).
  public bool HasLink(string channel) => Volatile.Read(ref current)?.HasLink(channel) == true;
  /// A message on a channel's link: null when the channel is not one of this relay's, true sent, false dropped (not
  /// moved yet, td.rt full, the link ending).
  public bool? SendDirect(string channel, byte[] message, LinkLane lane) => Volatile.Read(ref current)?.SendDirect(channel, message, lane);
  /// How a channel's link carries video now (M5): null when it has not moved.
  public LinkVideo? LinkVideo(string channel) => Volatile.Read(ref current)?.LinkVideo(channel);

  /// At start and on every trust change (Security M2): `eligible` = the devices that may hold a TURN login now
  /// (approved, not Hoot-only), `known` = every device the trust store has. A device that left the eligible set loses
  /// its link and its login, withdrawn unconditionally (an unpaired device too: its id is known at that moment). On the
  /// first call every known device that is not eligible is withdrawn as well: it may hold a login from before a restart
  /// (the relay room keeps them; nothing is stored on this PC).
  public void RefreshLinkDevices(IReadOnlyCollection<string> eligible, IReadOnlyCollection<string> known)
  {
    if (link is null || ice is null) return;
    HashSet<string> gone; bool first;
    lock (linkGate)
    {
      gone = [.. linkEligible.Where(d => !eligible.Contains(d))];
      first = !linkRefreshed; linkRefreshed = true;
      linkEligible = [.. eligible];
    }
    foreach (var device in gone)
    {
      Volatile.Read(ref current)?.EndLinksFor(device);
      _ = ice.ReleaseAsync(device, force: true);
    }
    if (first) foreach (var device in known.Where(d => !eligible.Contains(d))) _ = ice.ReleaseAsync(device, force: true);
  }

  /// The phone host is stopping: every TURN login is withdrawn now, before Dispose (Security S1, #27).
  public Task WithdrawLoginsAsync(TimeSpan within) => ice?.WithdrawAllAsync(within) ?? Task.CompletedTask;

  /// For tests: the devices holding a TURN login now.
  public IReadOnlyCollection<string> TurnHolders => ice?.Holders ?? [];
  public event Action<RelayConnectionState>? StateChanged;

  // ---- reach by account (port of the Mac's BackendRemoteRelayClient reach part) ------------------------------------
  /// The process's reach link: its door answers account channels, and while it holds a relay token this PC's room is
  /// tied to the account (the dial carries the token). Null: today's relay, exactly.
  public ReachRelayLink? Reach { get; init; }
  private string? dialedWithToken;
  private string? refusedToken;
  private CancellationTokenSource? socketStop;
  private volatile bool redial;
  /// Whether the current socket was dialed tied to the account (the page's state).
  public bool AccountTied => Volatile.Read(ref connected) != 0 && Volatile.Read(ref dialedWithToken) is not null;
  /// The shared token changed: a socket that is not tied (and should be), or tied while it should not be, is dialed again.
  internal void ReachTokenChanged()
  {
    if (Reach is null || Volatile.Read(ref running) == 0) return;
    var wanted = Reach.Token is not null;
    if (wanted == (Volatile.Read(ref dialedWithToken) is not null)) return;
    Volatile.Write(ref refusedToken, null);
    redial = true;
    try { Volatile.Read(ref socketStop)?.Cancel(); } catch (ObjectDisposedException) { }
  }
  /// Ends every account channel now (paired ones stay).
  internal Task CloseAccountChannelsAsync(IReadOnlyCollection<string>? deviceIds) => Volatile.Read(ref current)?.CloseAccountChannelsAsync(deviceIds) ?? Task.CompletedTask;
  // The token to dial with: only one with a minute left that the relay did not refuse.
  private string? DialToken()
  {
    if (Reach?.Token is not { } held || held.Token == Volatile.Read(ref refusedToken)) return null;
    return held.ExpiresAtMs - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() > 60_000 ? held.Token : null;
  }

  public RelayHostClient(Uri relay, ReadOnlySpan<byte> hostSecret, NoiseIdentity identity,
    IRelayPhoneApplication application, Func<IRelaySocket>? makeSocket = null, TimeProvider? clock = null, IRelayMcpApplication? mcp = null, IRelayReceiverApplication? receiver = null,
    ILinkEngine? linkEngine = null, HttpClient? turnHttp = null, Func<ReadOnlyMemory<byte>, string?>? linkEligible = null)
  {
    RelayEndpoint.Validate(relay);
    if (hostSecret.Length != 32) throw new ArgumentException("A host secret must be 32 bytes.");
    this.relay = relay;
    this.hostSecret = hostSecret.ToArray();
    this.identity = identity;
    this.application = application;
    this.makeSocket = makeSocket ?? (() => new RelayWebSocket());
    this.clock = clock ?? TimeProvider.System; this.mcp = mcp; this.receiver = receiver;
    // A phone host (it can tell which device a connection is) is direct only. Without a working WebRTC stack every link
    // fails with the reason and the phone is told: nothing goes over the relay instead (no hidden fallback).
    if (linkEligible is not null)
    {
      var logins = turn = new RelayTurnLogins(relay, hostSecret, () => Volatile.Read(ref connected) != 0, turnHttp);
      var source = ice = new LinkIceSource((device, ct) => logins.FetchAsync(device, 3600, ct), (device, login, ct) => logins.RevokeAsync(device, login, ct), this.clock);
      link = new LinkSetup(linkEngine ?? new UnavailableLinkEngine("This computer's direct-link engine is not installed."), source.ServersAsync)
      { Eligible = linkEligible, Release = source.ReleaseAsync };
    }
  }

  public static RelayHostClient ForRendezvous(Uri relay, RendezvousIdentity identity, IRelayPhoneApplication application) =>
    new(relay, identity.HostSecret, identity.Keys, application);

  public async Task RunAsync(CancellationToken cancellationToken)
  {
    if (Interlocked.Exchange(ref running, 1) != 0) throw new InvalidOperationException("This relay client is already running.");
    var attempt = 0;
    // ONE connection for this client's whole run, across relay sockets: a link-only phone's link (and its sessions)
    // outlives a relay reset (contract §11.4); everything else ends with the socket it came on.
    await using var connection = new RelayHostConnection(identity, application, mcp, clock, receiver, link) { Reach = Reach };
    Reach?.Add(this);
    void Moved(string channel) => LinkMoved?.Invoke(channel);
    connection.LinkMoved += Moved;
    Volatile.Write(ref current, connection);
    try
    {
      while (!cancellationToken.IsCancellationRequested)
      {
        await using (var socket = makeSocket())
        using (var thisSocket = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
          // Reach by account: the room is tied to the account only with a token that still has a minute left.
          var bearer = socket is IRelayReachSocket ? DialToken() : null;
          if (socket is IRelayReachSocket reachSocket) reachSocket.Bearer = bearer;
          Volatile.Write(ref dialedWithToken, bearer);
          Volatile.Write(ref socketStop, thisSocket);
          redial = false;
          var opened = false;
          try
          {
            StateChanged?.Invoke(RelayConnectionState.Connecting);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(thisSocket.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(15));
            await socket.ConnectAsync(RelayEndpoint.Host(relay), hostSecret, deadline.Token).ConfigureAwait(false);
            opened = true;
            StateChanged?.Invoke(RelayConnectionState.Connected);
            Volatile.Write(ref connected, 1);
            try { await connection.RunAsync(socket, thisSocket.Token, keepLinks: true).ConfigureAwait(false); }
            finally { Volatile.Write(ref connected, 0); }
          }
          catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
          catch (WebSocketException) when (!opened && bearer is not null && !redial)
          {
            // The relay refused the tied dial (a token it does not take): the next dial goes untied, so paired devices
            // keep reaching this PC; presence brings a fresh token.
            Volatile.Write(ref refusedToken, bearer);
            System.Diagnostics.Trace.WriteLine("reach: the relay did not take this PC's account token; dialing untied.");
          }
          catch (Exception ex) when (ex is WebSocketException or IOException or ProtocolException or OperationCanceledException)
          { /* Public status deliberately contains no transport headers or secrets. */ }
          catch (Exception ex)
          {
            // Any other failure reconnects too; the host never stays off the relay.
            System.Diagnostics.Trace.WriteLine("Relay connection ended: " + ex.GetType().Name);
          }
        }
        Volatile.Write(ref socketStop, null);
        StateChanged?.Invoke(RelayConnectionState.Disconnected);
        // A redial asked by reach (tie or untie) or a refused tied dial goes again at once.
        if (redial || Volatile.Read(ref refusedToken) is not null && Volatile.Read(ref dialedWithToken) is not null) { redial = false; continue; }
        var delay = TimeSpan.FromMilliseconds(Math.Min(30000, 500 * Math.Pow(2, Math.Min(attempt++, 6))));
        await Task.Delay(delay, clock, cancellationToken).ConfigureAwait(false);
      }
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    finally
    {
      Volatile.Write(ref current, null);
      Reach?.Remove(this);
      Volatile.Write(ref dialedWithToken, null);
      connection.LinkMoved -= Moved;
      Interlocked.Exchange(ref running, 0);
      StateChanged?.Invoke(RelayConnectionState.Stopped);
    }
  }

  public void Dispose()
  {
    if (Volatile.Read(ref running) != 0) throw new InvalidOperationException("Stop the relay client before disposing it.");
    CryptographicOperations.ZeroMemory(hostSecret);
    turn?.Dispose();
  }
}
