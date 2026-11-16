using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// Owner, 13 Nov: after sign-in Cloud is on for this PC by itself; one switch "Use Cloud on this PC" turns it off.
public sealed class CloudJoinTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-join-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  internal static async Task SignInAsync(CloudAccountClient account)
  {
    var url = await account.BeginSignInAsync();
    var q = url.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
    Assert.True(await account.FinishAppReturnAsync(new Uri($"terminaldeck://cloud/return/{q["callback"]}?code=Q29kZUZyb21UaGVXZWJzaXRlX19fX19fX19fX19fX19&state={q["state"]}")));
  }
  private CloudAccountClient Make(CloudServiceFake http, ProtectedCloudSecretStore store) =>
    new(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), store, http, new CountingRandom(), new FakeBrowser());

  [Fact] public async Task SignInJoinsByItselfAndCloudIsOn()
  {
    var http = new CloudServiceFake();
    var store = new ProtectedCloudSecretStore(Path.Combine(folder, "cloud", "account.protected"), new XorProtector());
    using var account = Make(http, store);
    await SignInAsync(account);
    // No question in between: the return alone registered this PC and opened Cloud.
    Assert.Single(http.Requests, r => r.Method == HttpMethod.Post && r.Url.AbsolutePath == "/v1/devices");
    Assert.Equal(CloudPhase.SignedIn, account.Snapshot.Phase); Assert.True(account.Snapshot.UseCloud);
    var page = CloudPageText.For(account.Snapshot);
    Assert.True(page.UseCloud);
    Assert.True(CloudTools.Status(account.Snapshot).GetProperty("useCloud").GetBoolean());
    Assert.Equal("On", CloudPageText.Account(account.Snapshot).CloudRow);
  }

  [Fact] public async Task TheSwitchTurnsCloudOffAndOnAndIsKept()
  {
    var http = new CloudServiceFake();
    var store = new ProtectedCloudSecretStore(Path.Combine(folder, "cloud", "account.protected"), new XorProtector());
    using var account = Make(http, store);
    await SignInAsync(account);
    await account.SetUseCloudAsync(false);
    Assert.Equal(CloudPhase.Paused, account.Snapshot.Phase); Assert.False(account.Snapshot.UseCloud);
    Assert.False(CloudPageText.For(account.Snapshot).UseCloud);
    Assert.Equal("Off on this PC", CloudPageText.Account(account.Snapshot).CloudRow);
    Assert.Equal("Off. Nothing of this PC is sent, and nothing from your Cloud arrives here. Nothing is deleted.", CloudPageText.UseCloudState(false));
    // A new start of the app keeps the choice; the sign-in and the device stay.
    using var again = Make(http, store);
    await again.ResumeAsync();
    Assert.Equal(CloudPhase.Paused, again.Snapshot.Phase); Assert.Equal(account.Snapshot.ThisDeviceId, again.Snapshot.ThisDeviceId);
    await again.SetUseCloudAsync(true);
    Assert.Equal(CloudPhase.SignedIn, again.Snapshot.Phase);
    Assert.Single(http.Requests, r => r.Method == HttpMethod.Post && r.Url.AbsolutePath == "/v1/devices");
  }

  [Fact] public async Task TheSwitchDoesNothingWithoutASignIn()
  {
    using var account = Make(new CloudServiceFake(), new ProtectedCloudSecretStore(Path.Combine(folder, "x"), new XorProtector()));
    await Assert.ThrowsAsync<CloudFailure>(() => account.SetUseCloudAsync(true));
    Assert.Null(CloudPageText.For(account.Snapshot).UseCloud);
    Assert.False(Directory.Exists(folder));
  }
}
