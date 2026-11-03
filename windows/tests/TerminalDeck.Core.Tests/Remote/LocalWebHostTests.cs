using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class LocalWebHostTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-local-web-" + Guid.NewGuid().ToString("N"));
  private sealed class Store : IDeviceTrustPersistence
  {
    private IReadOnlyList<StoredDevice> rows = [];
    public IReadOnlyList<StoredDevice> Load() => rows;
    public void Save(IReadOnlyList<StoredDevice> value) => rows = value;
  }
  private sealed class Sessions : IPhoneSessionView
  { public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => [JsonSerializer.SerializeToElement(new { id = "own-session", title = "Own session", cwd = "C:/work", provider = "shell", status = "idle" })]; }
  public LocalWebHostTests()
  {
    Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "index.html"), "<!doctype html><title>Private workspace</title>");
    File.WriteAllText(Path.Combine(root, "build.json"), "{\"client\":\"terminaldeck-web\",\"bootstrap\":1}");
  }
  public void Dispose() => Directory.Delete(root, true);
  private static async Task Send(ClientWebSocket socket, object value) => await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(value), WebSocketMessageType.Text, true, CancellationToken.None);
  private static async Task<JsonElement> Receive(ClientWebSocket socket)
  {
    using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(5)); using var bytes = new MemoryStream(); var buffer = new byte[4096];
    while (true) { var next = await socket.ReceiveAsync(buffer.AsMemory(), stop.Token); if (next.MessageType == WebSocketMessageType.Close) throw new IOException("Closed before reply"); bytes.Write(buffer, 0, next.Count); if (next.EndOfMessage) return JsonDocument.Parse(bytes.ToArray()).RootElement.Clone(); }
  }
  [Fact] public async Task BrowserPairsOnceReconnectsWithSavedCredentialAndRevokeClosesAuthority()
  {
    var trust = new DeviceTrust(new Store()); var grants = new HashSet<string>(); var hub = new PhoneTransportHub(new PhoneLink(trust, "PC", "0.20.3.0", new Sessions()));
    await using var host = new LocalWebHost(root, trust, hub, id => grants.Add(id)); var launch = new Uri(host.OpenUrl()); var fragment = launch.Fragment[1..].Split('&').Select(s => s.Split('=', 2)).ToDictionary(s => s[0], s => Uri.UnescapeDataString(s[1]));
    Assert.Equal(43, fragment["pair"].Length); var endpoint = new Uri(fragment["endpoint"]);
    using var first = new ClientWebSocket(); first.Options.SetRequestHeader("Origin", launch.GetLeftPart(UriPartial.Authority)); await first.ConnectAsync(endpoint, default);
    await Send(first, new { t = "hello", protocol = 1, token = fragment["pair"], device = new { name = "Edge", platform = "web" } });
    var paired = await Receive(first); var token = paired.GetProperty("token").GetString()!; Assert.Contains(paired.GetProperty("deviceId").GetString()!, grants); Assert.Empty(trust.KnownPeers);
    using var next = new ClientWebSocket(); next.Options.SetRequestHeader("Origin", launch.GetLeftPart(UriPartial.Authority)); await next.ConnectAsync(endpoint, default);
    await Send(next, new { t = "hello", protocol = 1, token, device = new { name = "Edge", platform = "web" } }); var welcome = await Receive(next);
    Assert.Equal("own-session", welcome.GetProperty("sessions")[0].GetProperty("id").GetString());
    trust.Revoke(paired.GetProperty("deviceId").GetString()!); await Send(next, new { t = "list" }); Assert.Equal("error", (await Receive(next)).GetProperty("t").GetString());
    using var revoked = new ClientWebSocket(); revoked.Options.SetRequestHeader("Origin", launch.GetLeftPart(UriPartial.Authority)); await revoked.ConnectAsync(endpoint, default);
    await Send(revoked, new { t = "hello", protocol = 1, token, device = new { name = "Edge", platform = "web" } }); Assert.Equal("unauthenticated", (await Receive(revoked)).GetProperty("code").GetString());
    using var replay = new ClientWebSocket(); replay.Options.SetRequestHeader("Origin", launch.GetLeftPart(UriPartial.Authority)); await replay.ConnectAsync(endpoint, default);
    await Send(replay, new { t = "hello", protocol = 1, token = fragment["pair"], device = new { name = "Other", platform = "web" } }); Assert.Equal("error", (await Receive(replay)).GetProperty("t").GetString());
  }
  [Fact] public async Task HttpChecksHostOriginPathAndServesBundleOfflineWithCsp()
  {
    var trust = new DeviceTrust(new Store()); var hub = new PhoneTransportHub(new PhoneLink(trust, "PC", "test", new Sessions())); await using var host = new LocalWebHost(root, trust, hub); host.Start();
    using var http = new HttpClient(); var response = await http.GetAsync(host.Address); Assert.True(response.IsSuccessStatusCode); Assert.Contains("Private workspace", await response.Content.ReadAsStringAsync()); Assert.Contains("frame-ancestors 'none'", response.Headers.GetValues("Content-Security-Policy").Single());
    using var forged = new HttpRequestMessage(HttpMethod.Get, host.Address); forged.Headers.Host = "attacker.invalid:" + host.Port; Assert.Equal(System.Net.HttpStatusCode.Forbidden, (await http.SendAsync(forged)).StatusCode);
    using var cross = new HttpRequestMessage(HttpMethod.Get, host.Address); cross.Headers.Add("Origin", "https://attacker.invalid"); Assert.Equal(System.Net.HttpStatusCode.Forbidden, (await http.SendAsync(cross)).StatusCode);
    Assert.False(host.AllowsHost("localhost.attacker.invalid:" + host.Port)); Assert.False(host.AllowsOrigin("null", "localhost:" + host.Port));
    // The hosted web version lives only at terminaldeck.app (as on the Mac); the retired app.terminaldeck.dev stays refused.
    Assert.True(host.AllowsOrigin("https://terminaldeck.app", "localhost:" + host.Port)); Assert.False(host.AllowsOrigin("https://app.terminaldeck.dev", "localhost:" + host.Port));
    Assert.False(host.AllowsOrigin("https://terminaldeck.app.attacker.invalid", "localhost:" + host.Port)); Assert.False(host.AllowsOrigin("http://terminaldeck.app", "localhost:" + host.Port));
  }
  private sealed class Clock : TimeProvider { public DateTimeOffset Now = DateTimeOffset.UtcNow; public override DateTimeOffset GetUtcNow() => Now; }
  [Fact] public void OffersExpireAndIndependentClicksDoNotCancelOtherPendingBrowserOffers()
  { var clock = new Clock(); var offers = new LocalWebOffers(clock); var a = offers.Create(); var b = offers.Create(); Assert.True(offers.Consume(a)); Assert.False(offers.Consume(a)); clock.Now += TimeSpan.FromSeconds(61); Assert.False(offers.Consume(b)); }
}
