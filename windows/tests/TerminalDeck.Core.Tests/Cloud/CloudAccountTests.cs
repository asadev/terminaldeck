using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Cloud;

public sealed class CloudAccountTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-tests-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private sealed record Setup(CloudAccountClient Account, CloudServiceFake Http, CountingRandom Random, FakeBrowser Browser, ProtectedCloudSecretStore Store, string Path, List<string> Log);
  private Setup Make()
  {
    var path = Path.Combine(folder, "cloud", "account.protected");
    var store = new ProtectedCloudSecretStore(path, new XorProtector());
    var http = new CloudServiceFake(); var random = new CountingRandom(); var browser = new FakeBrowser(); var log = new List<string>();
    var account = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), store, http, random, browser) { StageLog = log.Add };
    return new(account, http, random, browser, store, path, log);
  }
  private const string Code = "Q29kZUZyb21UaGVXZWJzaXRlX19fX19fX19fX19fX19";
  private static Uri Return(Uri start, string? token = null, string? state = null, string code = Code)
  {
    var q = Query(start);
    return new Uri($"terminaldeck://cloud/return/{token ?? q["callback"]}?code={code}&state={state ?? q["state"]}");
  }
  private static Dictionary<string, string> Query(Uri url) => url.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
  private static async Task SignInAsync(Setup c)
  {
    var url = await c.Account.BeginSignInAsync();
    Assert.True(await c.Account.FinishAppReturnAsync(Return(url)));
  }

  [Fact] public async Task NothingOfCloudExistsBeforeThePress()
  {
    var c = Make();
    await c.Account.ResumeAsync();
    Assert.Equal(CloudPhase.Dormant, c.Account.Snapshot.Phase);
    Assert.Empty(c.Http.Requests); Assert.Equal(0, c.Random.Calls); Assert.Empty(c.Browser.Opened);
    Assert.False(Directory.Exists(folder));
    var page = CloudPageText.For(c.Account.Snapshot);
    Assert.Equal(CloudPageText.SignedOutLine, page.Line); Assert.Equal("Sign in", page.Button);
    var account = CloudPageText.Account(c.Account.Snapshot);
    Assert.Equal("One Terminal Deck account for all your devices", account.Line); Assert.Equal("Sign in", account.Button); Assert.Null(account.CloudRow);
  }

  [Fact] public async Task BeginSendsTheBrowserThroughTheWebsiteWithTheAppKind()
  {
    var c = Make();
    var url = await c.Account.BeginSignInAsync();
    Assert.Equal("https://terminaldeck.dev/api/store/cloud/start", url.GetLeftPart(UriPartial.Path));
    var q = Query(url);
    Assert.Equal(["challenge", "state", "callback", "platform", "device"], q.Keys.ToArray());
    Assert.Equal(22, q["callback"].Length); Assert.Equal(43, q["state"].Length); Assert.Equal(43, q["challenge"].Length);
    Assert.Equal(("windows", "OFFICE-PC"), (q["platform"], q["device"]));
    Assert.DoesNotContain("port", url.Query);
    Assert.Single(c.Browser.Opened); Assert.Empty(c.Http.Requests); Assert.False(Directory.Exists(folder));
    Assert.Equal(CloudPhase.SigningIn, c.Account.Snapshot.Phase); Assert.True(c.Account.HasPendingSignIn);
    c.Account.CancelSignIn();
    Assert.Equal(CloudPhase.SignedOut, c.Account.Snapshot.Phase); Assert.False(c.Account.HasPendingSignIn);
    Assert.Equal(new string('x', 64), CloudAccountClient.StartDeviceLabel(new string('x', 70)));
  }

  [Fact] public async Task AReturnThatDoesNotAnswerThisAppsSignInDoesNothing()
  {
    var c = Make();
    // No sign-in started: nothing is sent, nothing changes, one plain line.
    Assert.False(await c.Account.FinishAppReturnAsync(new Uri($"terminaldeck://cloud/return/{new string('A', 22)}?code={Code}&state={new string('B', 43)}")));
    Assert.Equal(CloudPhase.Dormant, c.Account.Snapshot.Phase);
    var url = await c.Account.BeginSignInAsync();
    var q = Query(url);
    foreach (var link in new[] {
      Return(url, token: new string('A', 22)), Return(url, state: new string('B', 43)),
      new Uri($"terminaldeck://cloud/return/{q["callback"]}?code={Code}&state={q["state"]}&extra=1"),
      new Uri($"terminaldeck://cloud/return/{q["callback"]}?code={Code}"),
      new Uri($"terminaldeck://cloud/return/{q["callback"]}?code={Code}&code={Code}&state={q["state"]}"),
      new Uri($"terminaldeck://elsewhere/return/{q["callback"]}?code={Code}&state={q["state"]}") })
      Assert.False(await c.Account.FinishAppReturnAsync(link));
    Assert.Empty(c.Http.Requests); Assert.False(Directory.Exists(folder));
    Assert.Equal(CloudPhase.SigningIn, c.Account.Snapshot.Phase); Assert.True(c.Account.HasPendingSignIn);
    Assert.Equal(7, c.Log.Count);
    Assert.All(c.Log, line => Assert.StartsWith("cloud sign-in: return to app failed: ", line));
    Assert.Equal("cloud sign-in: return to app failed: no pending sign-in", c.Log[0]);
    Assert.Equal("cloud sign-in: return to app failed: sign-in does not match", c.Log[1]);
    Assert.Equal("cloud sign-in: return to app failed: not a sign-in return", c.Log[3]);
    // The right link still finishes afterwards.
    Assert.True(await c.Account.FinishAppReturnAsync(Return(url)));
    Assert.Equal(CloudPhase.SignedIn, c.Account.Snapshot.Phase);
  }

  [Fact] public async Task AReplayedReturnDoesNothing()
  {
    var c = Make();
    var url = await c.Account.BeginSignInAsync();
    Assert.True(await c.Account.FinishAppReturnAsync(Return(url)));
    var sent = c.Http.Requests.Count; var device = c.Account.Snapshot.ThisDeviceId;
    Assert.False(await c.Account.FinishAppReturnAsync(Return(url)));
    Assert.Equal(sent, c.Http.Requests.Count); Assert.Equal(device, c.Account.Snapshot.ThisDeviceId);
    Assert.Equal("cloud sign-in: return to app failed: no pending sign-in", c.Log[^1]);
  }

  [Fact] public async Task AnExpiredSignInIsNotFinished()
  {
    var time = new ManualClock(DateTimeOffset.UtcNow);
    var store = new ProtectedCloudSecretStore(Path.Combine(folder, "cloud", "account.protected"), new XorProtector());
    var http = new CloudServiceFake(); var log = new List<string>();
    var account = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), store, http, new CountingRandom(), new FakeBrowser(), time) { StageLog = log.Add };
    var url = await account.BeginSignInAsync();
    time.Now += TimeSpan.FromMinutes(6);
    Assert.False(await account.FinishAppReturnAsync(Return(url)));
    Assert.Empty(http.Requests);
    Assert.Equal("cloud sign-in: return to app failed: sign-in expired", log.Single());
  }
  private sealed class ManualClock(DateTimeOffset start) : TimeProvider
  {
    public DateTimeOffset Now = start;
    public override DateTimeOffset GetUtcNow() => Now;
  }

  [Fact] public async Task TheRightReturnFinishesByItselfWithOneLinePerStage()
  {
    var c = Make();
    var url = await c.Account.BeginSignInAsync();
    Assert.True(await c.Account.FinishAppReturnAsync(Return(url)));
    Assert.Equal(CloudPhase.SignedIn, c.Account.Snapshot.Phase);
    // The exchange carries exactly the app callback, the same object the website started with.
    Assert.Equal($"{{\"kind\":\"app\",\"pathToken\":\"{Query(url)["callback"]}\",\"platform\":\"windows\"}}", c.Http.ExchangeCallback);
    Assert.Equal(["cloud sign-in: return to app ok", "cloud sign-in: code exchange ok", "cloud sign-in: save sign-in ok", "cloud sign-in: Cloud status ok",
      "cloud sign-in: device registration ok", "cloud sign-in: devices ok", "cloud sign-in: finished"], c.Log.ToArray());
    foreach (var line in c.Log)
      foreach (var secret in new[] { Code, Query(url)["state"], Query(url)["callback"], "someone@example.com", "Someone", "OFFICE-PC", c.Http.Verifier! })
        Assert.DoesNotContain(secret, line);
  }

  [Fact] public async Task SignInRegistersThisPcAndShowsTheDevices()
  {
    var c = Make();
    var url = await c.Account.BeginSignInAsync();
    Assert.True(await c.Account.FinishAppReturnAsync(Return(url)));
    Assert.Equal(Query(url)["challenge"], CloudWire.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(c.Http.Verifier!))));
    Assert.Equal(64, c.Http.Verifier!.Length);
    Assert.Equal(["/v1/auth/exchange", "/v1/capabilities", "/v1/devices", "/v1/devices"], c.Http.Requests.Select(r => r.Url.AbsolutePath).ToArray());
    Assert.Equal("windows", c.Http.Registered!.Platform); Assert.Equal("OFFICE-PC", c.Http.Registered.Label);
    var s = c.Account.Snapshot;
    Assert.Equal(CloudPhase.SignedIn, s.Phase); Assert.Equal("someone@example.com", s.Email);
    Assert.Equal(2, s.DeviceRows.Count);
    Assert.True(s.DeviceRows[0].ThisDevice); Assert.Equal("Asad's Mac mini", s.DeviceRows[1].Name);
    var page = CloudPageText.For(s, d => d.UtcDateTime.ToString("yyyy-MM-dd"));
    Assert.Equal("Signed in as someone@example.com.", page.Line); Assert.Equal("Sign out", page.Button); Assert.Equal("OFFICE-PC", page.ThisDevice);
    Assert.Equal("OFFICE-PC", page.Devices[0].Name);
    var account = CloudPageText.Account(s);
    Assert.Equal(("Someone", "someone@example.com", "Signed in with Google", "On"), (account.Name, account.Email, account.Provider, account.CloudRow)); Assert.Null(account.Button);
    Assert.Equal("This PC · Added 2025-11-13 · Last seen 2025-11-13", page.Devices[0].Details);
    Assert.Equal("Added 2025-10-20 · Last seen 2025-11-01", page.Devices[1].Details);
    // A fresh process finds the same sign-in and device in the protected record.
    var again = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), c.Store, c.Http, new CountingRandom(), new FakeBrowser());
    await again.ResumeAsync();
    Assert.Equal(CloudPhase.SignedIn, again.Snapshot.Phase); Assert.Equal(s.ThisDeviceId, again.Snapshot.ThisDeviceId);
    Assert.Equal(1, c.Http.Requests.Count(r => r.Method == HttpMethod.Post && r.Url.AbsolutePath == "/v1/devices"));
  }

  [Fact] public async Task AnAccountWithoutCloudStaysSignedInAndRegistersNothing()
  {
    var c = Make(); c.Http.Entitled = false;
    await SignInAsync(c);
    Assert.Equal(CloudPhase.NotAllowed, c.Account.Snapshot.Phase);
    Assert.DoesNotContain(c.Http.Requests, r => r.Url.AbsolutePath == "/v1/devices");
    Assert.True(File.Exists(c.Path));
    var page = CloudPageText.For(c.Account.Snapshot);
    Assert.Equal("You are signed in as someone@example.com. Cloud is not open for this account yet.", page.Line);
    Assert.Equal("Sign out", page.Button); Assert.Empty(page.Devices);
    Assert.Equal("Not open for this account yet", CloudPageText.Account(c.Account.Snapshot).CloudRow);
  }

  [Fact] public async Task ThePrivateKeyAndTokensNeverAppearInAFileOrAnyOutput()
  {
    var c = Make();
    var log = new StringWriter();
    c.Account.Changed += s => log.WriteLine(s.ToString());
    await SignInAsync(c);
    var plain = Encoding.UTF8.GetString(new XorProtector().Unprotect(File.ReadAllBytes(c.Path)));
    using var record = JsonDocument.Parse(plain);
    var secrets = new[] { record.RootElement.GetProperty("signing").GetString()!, record.RootElement.GetProperty("wrapping").GetString()!,
      record.RootElement.GetProperty("session").GetProperty("accessToken").GetString()!, "refresh-secret-value" };
    var files = Directory.GetFiles(folder, "*", SearchOption.AllDirectories);
    Assert.Equal([c.Path], files);
    var onDisk = Encoding.UTF8.GetString(File.ReadAllBytes(c.Path));
    foreach (var output in new[] { onDisk, log.ToString(), CloudTools.Status(c.Account.Snapshot).GetRawText(), string.Join("\n", c.Http.Requests.Select(r => r.ToString())), c.Account.Snapshot.ToString() })
      foreach (var secret in secrets) Assert.DoesNotContain(secret, output);
    // The private key in the record is a real P-256 key and differs from everything the service saw.
    using var key = ECDsa.Create(); key.ImportPkcs8PrivateKey(CloudWire.FromBase64Url(secrets[0]), out _);
    Assert.DoesNotContain(c.Http.Requests, r => Encoding.UTF8.GetString(r.Body).Contains(secrets[0], StringComparison.Ordinal));
  }

  [Fact] public async Task SignOutRemovesTheRecordAndEndsTheSession()
  {
    var c = Make();
    await SignInAsync(c);
    var device = c.Account.Snapshot.ThisDeviceId!;
    var before = c.Http.Requests.Count;
    await c.Account.SignOutAsync();
    Assert.Equal(CloudPhase.SignedOut, c.Account.Snapshot.Phase); Assert.False(File.Exists(c.Path));
    // This PC is removed from the account at the service, then the session ends; its keys are gone with the record.
    Assert.Equal(["/v1/state", "/v1/devices/remove", "/auth/v1/logout"], c.Http.Requests.Skip(before).Select(r => r.Url.AbsolutePath));
    Assert.Equal([device], c.Http.Removed);
    Assert.Equal("cloud sign-out: remove this PC ok", c.Log[^1]);
    Assert.Equal("Sign out of Cloud on this PC?", CloudPageText.SignOutTitle);
    Assert.Equal("Your work stays on this PC. It stops syncing with your other devices until you sign in again.", CloudPageText.SignOutText);
    var logout = c.Http.Requests.Last();
    Assert.EndsWith("/auth/v1/logout", logout.Url.AbsolutePath); Assert.StartsWith("Bearer ", logout.Headers["Authorization"]);
    Assert.Equal("Sign in", CloudPageText.For(c.Account.Snapshot).Button);
    await c.Account.ResumeAsync();
    Assert.Equal(CloudPhase.Dormant, c.Account.Snapshot.Phase);
  }

  [Fact] public async Task ARevokedDeviceSignsOutButNoAnswerKeepsTheSignIn()
  {
    var c = Make();
    await SignInAsync(c);
    c.Http.RefuseDevicesWith = "temporarily_unavailable";
    await c.Account.RefreshAsync();
    Assert.Equal(CloudPhase.SignedIn, c.Account.Snapshot.Phase); Assert.NotNull(c.Account.Snapshot.Problem); Assert.True(File.Exists(c.Path));
    c.Http.RefuseDevicesWith = "device_revoked";
    await Assert.ThrowsAsync<CloudFailure>(() => c.Account.RefreshAsync());
    Assert.Equal(CloudPhase.SignedOut, c.Account.Snapshot.Phase); Assert.False(File.Exists(c.Path));
  }

  [Fact] public async Task EveryAddressComesFromTheEndpointsInterface()
  {
    var moved = new FixedAccountEndpoints(new Uri("https://id.example.test/start"), new Uri("https://id.example.test/exchange"), new Uri("https://cloud.example.test/v1"),
      new Uri("https://id.example.test/token"), new Uri("https://id.example.test/logout"), CloudWire.Issuer);
    var http = new CloudServiceFake();
    var account = new CloudAccountClient(new CloudConfiguration(moved, "OFFICE-PC", "0.22.0.0"), new ProtectedCloudSecretStore(Path.Combine(folder, "a"), new XorProtector()),
      http, new CountingRandom(), new FakeBrowser());
    var url = await account.BeginSignInAsync();
    Assert.Equal("id.example.test", url.Host);
    Assert.True(await account.FinishAppReturnAsync(Return(url)));
    await account.SignOutAsync();
    Assert.All(http.Requests, r => Assert.EndsWith(".example.test", r.Url.Host));
    Assert.Throws<CloudFailure>(() => new CloudAccountClient(new CloudConfiguration(moved with { CloudBase = new Uri("http://cloud.example.test/v1") }, "PC", "1"),
      new ProtectedCloudSecretStore(Path.Combine(folder, "b"), new XorProtector()), http, new CountingRandom(), new FakeBrowser()));
  }

  [Fact] public void AgentsGetOneReadToolAndNoWayToSignIn()
  {
    Assert.Equal(["cloud.status"], CloudTools.Specs.Select(s => s.Id).ToArray());
    Assert.All(CloudTools.Specs, s => Assert.Equal(McpTier.Read, s.Tier));
    var status = CloudTools.Status(CloudSnapshot.Dormant);
    Assert.Equal("dormant", status.GetProperty("phase").GetString()); Assert.False(status.GetProperty("cloudOpen").GetBoolean());
  }
}
