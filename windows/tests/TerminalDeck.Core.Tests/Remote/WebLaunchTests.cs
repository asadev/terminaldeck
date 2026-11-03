using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class WebLaunchTests
{
  [Fact]
  public void GrantWorksOnceAndNewClickInvalidatesPreviousLink()
  {
    var grant = new WebLaunch();
    var old = grant.Issue(); var current = grant.Issue();
    Assert.False(grant.Consume(old)); Assert.False(grant.Consume(current + "x"));
    Assert.True(grant.Consume(current)); Assert.False(grant.Consume(current)); Assert.False(grant.IsOpen);
  }

  [Fact]
  public void ExpiredGrantNeverRedeems()
  {
    var time = new Clock(); var launch = new WebLaunch(time); var token = launch.Issue();
    time.Now = time.Now.AddSeconds(60);
    Assert.False(launch.IsOpen); Assert.False(launch.Consume(token));
  }

  private sealed class Clock : TimeProvider
  {
    public DateTimeOffset Now { get; set; } = DateTimeOffset.UnixEpoch;
    public override DateTimeOffset GetUtcNow() => Now;
  }

  [Theory]
  [InlineData("[]")]
  [InlineData("{\"t\":3}")]
  [InlineData("{\"t\":\"hello\",\"token\":3}")]
  public async Task MalformedFramesBecomeProtocolRefusals(string json)
  {
    var trust = new DeviceTrust(new TestTrustStore()); var grant = new WebLaunch(); grant.Issue();
    using var browser = NoiseIdentity.Generate();
    using var app = new WebLaunchApplication(new PhoneLink(trust, "PC", "test", new EmptyView()), trust, grant);
    await Assert.ThrowsAsync<ProtocolException>(async () => await app.ReceiveAsync("bad", browser.PublicKey, System.Text.Encoding.UTF8.GetBytes(json), CancellationToken.None));
    Assert.True(grant.IsOpen); Assert.Empty(trust.List());
  }

  [Fact]
  public async Task BrowserEnrollmentUsesNoisePeerAndLeavesPhoneCodeAlone()
  {
    var trust = new DeviceTrust(new TestTrustStore());
    var phoneCode = trust.Pairing.Create().Code;
    var grant = new WebLaunch(); var token = grant.Issue();
    using var browser = NoiseIdentity.Generate(); using var other = NoiseIdentity.Generate();
    using var app = new WebLaunchApplication(new PhoneLink(trust, "PC", "test", new EmptyView()), trust, grant);
    var hello = JsonSerializer.SerializeToUtf8Bytes(new { t = "hello", protocol = 1, token, device = new { name = "Edge on Windows", platform = "Windows" } });
    var reply = await app.ReceiveAsync("browser", browser.PublicKey, hello, CancellationToken.None);
    using var welcome = JsonDocument.Parse(Assert.Single(reply.Messages));
    var credential = welcome.RootElement.GetProperty("token").GetString()!;
    Assert.Equal("web", trust.Authenticate(credential, browser.PublicKey).Platform);
    Assert.Equal(PhoneAccess.Full, trust.Authenticate(credential, browser.PublicKey).Access);
    Assert.Throws<ProtocolException>(() => trust.Authenticate(credential, other.PublicKey));
    Assert.True(trust.Pairing.IsCurrent(phoneCode));
    await Assert.ThrowsAsync<ProtocolException>(async () => await app.ReceiveAsync("replay", other.PublicKey, hello, CancellationToken.None));
    trust.Revoke(Assert.Single(trust.List()).Id);
    Assert.Throws<ProtocolException>(() => trust.Authenticate(credential, browser.PublicKey));
  }
  [Fact]
  public async Task FreshEnrollmentGrantsWorkspaceBeforeWelcomeButReopenPreservesUserChoice()
  {
    var trust = new DeviceTrust(new TestTrustStore()); var launch = new WebLaunch();
    var granted = new HashSet<string>(); var callbacks = 0;
    using var browser = NoiseIdentity.Generate();
    using var app = new WebLaunchApplication(new PhoneLink(trust, "PC", "test", new GrantedView(granted)), trust, launch,
      id => { callbacks++; granted.Add(id); });
    byte[] Hello(string token) => JsonSerializer.SerializeToUtf8Bytes(new { t = "hello", protocol = 1, token, device = new { name = "Edge on Windows", platform = "web" } });
    var first = await app.ReceiveAsync("first", browser.PublicKey, Hello(launch.Issue()), default);
    using var welcome = JsonDocument.Parse(Assert.Single(first.Messages));
    var id = welcome.RootElement.GetProperty("deviceId").GetString()!;
    Assert.Contains(id, granted); Assert.Equal(1, callbacks);
    // A later desktop access choice must survive another explicit Open web click.
    trust.Approve(id, PhoneAccess.Look); granted.Clear();
    var second = await app.ReceiveAsync("second", browser.PublicKey, Hello(launch.Issue()), default);
    using var reopened = JsonDocument.Parse(Assert.Single(second.Messages));
    Assert.Equal(id, reopened.RootElement.GetProperty("deviceId").GetString());
    Assert.Equal(1, callbacks); Assert.Empty(granted);
    Assert.Equal(PhoneAccess.Look, Assert.Single(trust.List()).Access);
  }

  [Fact]
  public async Task FailedFreshWorkspaceGrantRevokesTheUnfinishedEnrollment()
  {
    var trust = new DeviceTrust(new TestTrustStore()); var launch = new WebLaunch(); using var browser = NoiseIdentity.Generate();
    using var app = new WebLaunchApplication(new PhoneLink(trust, "PC", "test", new EmptyView()), trust, launch,
      _ => throw new IOException("Disk unavailable"));
    var hello = JsonSerializer.SerializeToUtf8Bytes(new { t = "hello", protocol = 1, token = launch.Issue(), device = new { name = "Browser", platform = "web" } });
    await Assert.ThrowsAsync<ProtocolException>(async () => await app.ReceiveAsync("first", browser.PublicKey, hello, default));
    Assert.Empty(trust.List()); Assert.False(launch.IsOpen);
  }

  private sealed class GrantedView(HashSet<string> granted) : IPhoneSessionView
  {
    public IReadOnlyList<JsonElement> Read(ApprovedDevice device)
    {
      // This mimics Task/Hoot's separate grant gate: Full alone is insufficient.
      if (device.Access == PhoneAccess.Full && !granted.Contains(device.Id)) throw new InvalidOperationException("Welcome arrived before workspace grant.");
      return [];
    }
  }
  private sealed class EmptyView : IPhoneSessionView { public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => []; }
}
