namespace TerminalDeck.Core.Cloud;

// W3 wiring: the bridge from the signed-in account to the sync engine. It builds the engine only while the account is
// signed in with "Use Cloud on this PC" on (the account's SyncIdentity), and drops it the moment either ends. While it
// runs: a round now, then one every few minutes, plus a round on each hint of the live event connection; the account is
// asked again now and then (in automatic trust mode new devices join this PC's list there); a device this PC newly
// trusts has what waited from it released at once. With no record kind registered the engine is built but stays idle:
// no timer, no event connection, no request, no file written. 7C-1 registers Deck Memory.

/// What the bridge takes from the platform. `Store(subject)`: the account's own sync folder. `Http` is called only when
/// a round actually sends. `Owners(subject, deviceId)`: the record kinds this PC syncs for that account (Deck Memory).
public sealed record CloudSyncPlatform(Func<string, CloudSyncStore> Store, Func<ICloudSyncHttp> Http, ICloudSyncSocketFactory Sockets, CloudSyncEndpoint Endpoint,
  Func<string, string, IReadOnlyList<ICloudSyncAdapter>> Owners, Func<long>? Clock = null);

public sealed class CloudSyncBridge : IDisposable
{
  public static readonly TimeSpan RoundEvery = TimeSpan.FromMinutes(5);
  public static readonly TimeSpan AccountEvery = TimeSpan.FromMinutes(15);
  public static readonly TimeSpan HaltGrace = TimeSpan.FromSeconds(2);

  private sealed class Running(string subject, string deviceId, CloudSyncEngine engine, CloudFeedClient client, LazySyncHttp http, CancellationTokenSource stop)
  {
    public string Subject { get; } = subject;
    public string DeviceId { get; } = deviceId;
    public CloudSyncEngine Engine { get; } = engine;
    public CloudFeedClient Client { get; } = client;
    public LazySyncHttp Http { get; } = http;
    public CancellationTokenSource Stop { get; } = stop;
    public SemaphoreSlim Poke { get; } = new(0, 1);
    public HashSet<string>? Trusted;
    public long AccountAskedAt;
  }

  private readonly ICloudSyncAccount account;
  private readonly CloudSyncPlatform platform;
  private readonly Action<string> log;
  private readonly Func<TimeSpan, CancellationToken, Task> delay;
  private readonly Func<long> now;
  private readonly object gate = new();
  private Running? running;
  private CloudSyncState? status;
  private bool started, disposed;

  public CloudSyncBridge(ICloudSyncAccount account, CloudSyncPlatform platform, Action<string>? log = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
  {
    this.account = account; this.platform = platform; this.log = log ?? (_ => { });
    this.delay = delay ?? Task.Delay; now = platform.Clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
  }

  /// What the Cloud page shows under "Use Cloud on this PC"; null while sync is not running (signed out, or Cloud off).
  public CloudSyncState? Status { get { lock (gate) return status; } }
  public event Action<CloudSyncState?>? StatusChanged;
  /// The engine while it runs (tests and diagnostics).
  public CloudSyncEngine? Engine { get { lock (gate) return running?.Engine; } }

  /// Follows the account from now on. Builds nothing unless the account is already signed in with Cloud on.
  public void Start()
  {
    lock (gate) { if (started || disposed) return; started = true; }
    account.Changed += OnAccount;
    OnAccount(account.Snapshot);
  }

  private void OnAccount(CloudSnapshot snapshot)
  {
    Running? stop = null, start = null; var launch = false; IReadOnlyCollection<string>? release = null;
    lock (gate)
    {
      if (disposed) return;
      var identity = account.SyncIdentity;
      if (running is { } r && (identity is null || identity.Value.Subject != r.Subject || identity.Value.DeviceId != r.DeviceId)) { stop = r; running = null; }
      if (identity is { } id && running is null)
      {
        start = Build(id.Subject, id.DeviceId);
        running = start; launch = true;
      }
      if (running is { } current)
      {
        var trusted = snapshot.DeviceRows.Where(d => !d.ThisDevice && d.Trust is { Standing: CloudTrustStanding.Trusted, Removed: false, KeyChanged: false })
          .Select(d => d.DeviceId).ToHashSet(StringComparer.Ordinal);
        if (current.Trusted is { } before && trusted.Except(before).ToArray() is { Length: > 0 } added) release = added;
        current.Trusted = trusted;
      }
    }
    if (stop is not null) Halt(stop);
    if (launch) Launch(start);
    else if (stop is not null) Publish(null);
    if (release is not null && running is { } live && live.Engine.HasKinds) _ = ReleaseAsync(live, release);
  }

  private Running? Build(string subject, string deviceId)
  {
    try
    {
      var store = platform.Store(subject);
      var http = new LazySyncHttp(platform.Http);
      var client = new CloudFeedClient(platform.Endpoint, subject, account, http, store, platform.Clock);
      var engine = new CloudSyncEngine(subject, deviceId, client, store, account.SyncTrust, account.SignPack, platform.Owners(subject, deviceId), log, platform.Clock);
      // The account was just asked (that is what started this); the next ask is due a while from now.
      return new(subject, deviceId, engine, client, http, new CancellationTokenSource()) { AccountAskedAt = now() };
    }
    catch (Exception error) when (error is not OutOfMemoryException)
    {
      log("cloud sync: start failed: " + CloudRefusal.Word(CloudRefusal.Classify(error)));
      return null;
    }
  }

  private void Launch(Running? r)
  {
    if (r is null) { Publish(new(CloudSyncPhase.Waiting, 0, 0, "this PC's sync record cannot be read", 0, 0, 0, 0, 0)); return; }
    Publish(r.Engine.State());
    if (!r.Engine.HasKinds) return; // Idle and silent: nothing on this PC syncs yet.
    var ct = r.Stop.Token;
    _ = Task.Run(() => LoopAsync(r, ct), CancellationToken.None);
    _ = Task.Run(async () =>
    {
      try { await r.Client.ListenAsync(platform.Sockets, e => { if (e.Type is "hello" or "changed") Nudge(r); return Task.CompletedTask; }, ct, delay); }
      catch (Exception error) when (error is not OutOfMemoryException) { if (!ct.IsCancellationRequested) log("cloud sync: events failed: " + CloudRefusal.Word(CloudRefusal.Classify(error))); }
    }, CancellationToken.None);
  }

  private static void Nudge(Running r) { try { if (r.Poke.CurrentCount == 0) r.Poke.Release(); } catch (SemaphoreFullException) { } catch (ObjectDisposedException) { } }

  private async Task LoopAsync(Running r, CancellationToken ct)
  {
    try
    {
      while (!ct.IsCancellationRequested)
      {
        await RoundAsync(r, ct);
        using var wake = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var timer = delay(RoundEvery, wake.Token);
        var poked = r.Poke.WaitAsync(wake.Token);
        await Task.WhenAny(timer, poked);
        await wake.CancelAsync();
        try { await Task.WhenAll(timer, poked); } catch (OperationCanceledException) { }
      }
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception error) when (error is not OutOfMemoryException) { log("cloud sync: stopped: " + CloudRefusal.Word(CloudRefusal.Classify(error))); }
  }

  private async Task<CloudSyncState> RoundAsync(Running r, CancellationToken ct)
  {
    if (now() - r.AccountAskedAt >= (long)AccountEvery.TotalMilliseconds)
    {
      r.AccountAskedAt = now();
      try { await account.RefreshAsync(ct); }
      catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException) { }
    }
    ct.ThrowIfCancellationRequested();
    var state = await r.Engine.SyncAsync(ct);
    if (IsCurrent(r)) Publish(state);
    return state;
  }

  private async Task ReleaseAsync(Running r, IReadOnlyCollection<string> devices)
  {
    try { await r.Engine.ReleaseHeldAsync(devices, r.Stop.Token); if (IsCurrent(r)) Publish(r.Engine.State()); }
    catch (Exception error) when (error is not OutOfMemoryException) { }
  }

  /// The page's "Sync now": clears a stop the person can clear and runs one round at once. Null while sync is not running.
  public async Task<CloudSyncState?> SyncNowAsync(CancellationToken ct = default)
  {
    Running? r; lock (gate) r = running;
    if (r is null) return null;
    if (!r.Engine.HasKinds) return r.Engine.State();
    r.Client.Backoff.Resume(userRetry: true);
    using var both = CancellationTokenSource.CreateLinkedTokenSource(ct, r.Stop.Token);
    try { return await RoundAsync(r, both.Token); }
    catch (OperationCanceledException) when (r.Stop.IsCancellationRequested) { return Status; }
  }

  private bool IsCurrent(Running r) { lock (gate) return ReferenceEquals(running, r); }

  private void Publish(CloudSyncState? next)
  {
    lock (gate) status = next;
    try { StatusChanged?.Invoke(next); } catch (Exception error) when (error is not OutOfMemoryException) { }
  }

  /// Signed out, Cloud turned off, or the app closing: the loop and the event connection end, the memory keys held in
  /// memory are forgotten, and the HTTP client (if one was ever made) is closed. Nothing is deleted.
  private void Halt(Running r)
  {
    r.Stop.Cancel();
    _ = Task.Run(async () =>
    {
      // Give a round in flight a moment to see the cancellation before its keys are dropped. The wait is the
      // bridge's own injectable one, so tests never sleep through it.
      try { await delay(HaltGrace, CancellationToken.None); } catch (Exception) { }
      r.Engine.Forget(); r.Http.Dispose();
    });
  }

  public void Dispose()
  {
    Running? r;
    lock (gate) { if (disposed) return; disposed = true; r = running; running = null; status = null; }
    account.Changed -= OnAccount;
    if (r is not null) { r.Stop.Cancel(); r.Engine.Forget(); r.Http.Dispose(); }
  }
}

/// Makes the sync HTTP client on the first request that is actually sent, never before.
public sealed class LazySyncHttp(Func<ICloudSyncHttp> make) : ICloudSyncHttp, IDisposable
{
  private readonly object gate = new();
  private ICloudSyncHttp? inner;
  private bool closed;
  public bool Created { get { lock (gate) return inner is not null; } }
  public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken ct)
  {
    ICloudSyncHttp made;
    lock (gate) { if (closed) throw new OperationCanceledException(); made = inner ??= make(); }
    return made.SendAsync(request, ct);
  }
  public void Dispose()
  {
    ICloudSyncHttp? made;
    lock (gate) { closed = true; made = inner; inner = null; }
    (made as IDisposable)?.Dispose();
  }
}
