namespace TerminalDeck.Core.Cloud;

/// How the app puts Cloud together at start-up. Building it does nothing: no request, no key, no file, no listener. The
/// HTTP client itself is made on the first request, which only follows the person's own Sign in (or resuming a sign-in
/// that already exists on this PC).
public static class CloudComposition
{
  public static CloudAccountClient Create(CloudConfiguration configuration, ICloudSecretStore store, ICloudBrowser browser,
    ICloudHttp? http = null, ICloudRandom? random = null, CloudTrustPorts? trust = null) =>
    new(configuration, store, http ?? new LazyCloudHttp(() => new HttpClientCloudHttp()), random ?? new SystemCloudRandom(), browser, trust: trust);
}

/// Makes the real HTTP client on its first request, never before.
public sealed class LazyCloudHttp(Func<ICloudHttp> make) : ICloudHttp, IDisposable
{
  private readonly Lazy<ICloudHttp> inner = new(make, LazyThreadSafetyMode.ExecutionAndPublication);
  public bool Created => inner.IsValueCreated;
  public Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct) => inner.Value.SendAsync(request, ct);
  public void Dispose() { if (inner.IsValueCreated && inner.Value is IDisposable made) made.Dispose(); }
}
