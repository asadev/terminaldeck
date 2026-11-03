using System.Security.Cryptography;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class RemoteService
{
  private readonly SemaphoreSlim lifecycleGate = new(1, 1);
  private DateTimeOffset? relayStarted;
  private int hostDisposed;
  private readonly object hostSecretGate = new();
  public PhonePushRelay? PushRelay()
  {
    lock (hostSecretGate) return hostSecret is null ? null : new(PairingCode.HostId(hostSecret), (byte[])hostSecret.Clone(), new Uri("https://relay.terminaldeck.dev/"));
  }
  private void SetHostSecret(byte[] value)
  {
    lock (hostSecretGate)
    {
      if (hostSecret is not null && !ReferenceEquals(hostSecret, value)) CryptographicOperations.ZeroMemory(hostSecret);
      hostSecret = value;
    }
    relayStarted = DateTimeOffset.UtcNow;
  }
  public async Task StartAsync()
  {
    await lifecycleGate.WaitAsync(stop.Token);
    try { if (relay is not null && !phonesEnabled) await EndHostEpochAsync(CancellationToken.None); await StartHostCoreAsync(); }
    catch { await EndHostEpochAsync(CancellationToken.None); throw; }
    finally { lifecycleGate.Release(); }
  }
  private async ValueTask EndHostEpochAsync(CancellationToken ct)
  {
    Trust.Changed -= OnTrustChangedForLinks;
    pairingStop?.Cancel(); relayRun?.Cancel();
    if (localWeb is not null) { await localWeb.DisposeAsync(); localWeb = null; }
    transportHub = null;
    try { await Task.WhenAll(tasks.ToArray()).WaitAsync(TimeSpan.FromSeconds(5), ct); }
    catch (Exception e) when (e is OperationCanceledException or TimeoutException or IOException or System.Net.WebSockets.WebSocketException) { }
    // Security S1 (#27): device access off for the whole app, or the app closing: withdraw every phone's TURN login now,
    // while the host secret still exists (the 2-minute timers would fire after the relay client is gone).
    if (relay is not null)
      try { await relay.WithdrawLoginsAsync(TimeSpan.FromSeconds(5)); }
      catch (Exception e) when (e is not OutOfMemoryException) { System.Diagnostics.Trace.WriteLine("TURN logins not withdrawn at stop: " + e.GetType().Name); }
    relay?.Dispose(); relay = null;
    (application as IDisposable)?.Dispose(); application = null;
    identity?.Dispose(); identity = null;
    relayRun?.Dispose(); relayRun = null; pairingStop?.Dispose(); pairingStop = null;
    lock (hostSecretGate) { if (hostSecret is not null) CryptographicOperations.ZeroMemory(hostSecret); hostSecret = null; }
    tasks.Clear(); relayStarted = null; phonesEnabled = false;
    State = RelayConnectionState.Stopped; Changed?.Invoke();
  }
  public async ValueTask<string> ControlHostAsync(bool restart, CancellationToken ct)
  {
    await lifecycleGate.WaitAsync(ct);
    try
    {
      await EndHostEpochAsync(ct);
      if (restart)
      {
        try { await StartHostCoreAsync(); }
        catch { await EndHostEpochAsync(CancellationToken.None); throw; }
      }
      else if (ReceiverTransportRequired?.Invoke() == true) await StartHostCoreAsync(enablePhones: false);
      return restart ? "Phone host restarted. Reconnect this device." : "Phone host stopped. Sessions are still running on this computer.";
    }
    finally { lifecycleGate.Release(); }
  }
  public async Task EnsureReceiverTransportAsync()
  {
    await lifecycleGate.WaitAsync(stop.Token);
    try { if (relay is null && ReceiverTransportRequired?.Invoke() == true) await StartHostCoreAsync(enablePhones: false); }
    catch { await EndHostEpochAsync(CancellationToken.None); throw; }
    finally { lifecycleGate.Release(); }
  }
  private sealed class ReceiverOnlyPhoneApplication : IRelayPhoneApplication
  {
    public IReadOnlyCollection<byte[]> KnownPeers => [];
    public bool PairingOpen => false;
    public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peer, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new ProtocolException("The phone host is stopped on this computer.");
    public ValueTask DisconnectedAsync(string channel) => ValueTask.CompletedTask;
  }
  public object HostFacts() => new { running = phonesEnabled && relay is not null, version = AppVersion, address = McpAddress,
    pid = Environment.ProcessId, startedAt = relayStarted?.ToUnixTimeMilliseconds(), uptimeSeconds = relayStarted is { } start ? (DateTimeOffset.UtcNow - start).TotalSeconds : (double?)null, managed = false };
}
