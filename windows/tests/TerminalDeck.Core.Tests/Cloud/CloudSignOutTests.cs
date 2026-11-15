using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// Sign-out removes this PC from the account at the service and drops its key; the network never blocks it.
public sealed class CloudSignOutTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-signout-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private (CloudAccountClient Account, CloudServiceFake Http, List<string> Log, string Path) Make()
  {
    var http = new CloudServiceFake(); var log = new List<string>();
    var path = Path.Combine(folder, "cloud", "account.protected");
    var account = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), new ProtectedCloudSecretStore(path, new XorProtector()), http,
      new CountingRandom(), new FakeBrowser()) { StageLog = log.Add };
    return (account, http, log, path);
  }

  [Fact] public async Task AVaultChangeInBetweenIsReadOnceMore()
  {
    var (account, http, log, path) = Make();
    await CloudJoinTests.SignInAsync(account);
    http.RemoveConflicts = 1;
    await account.SignOutAsync();
    Assert.Equal([http.Registered!.DeviceId], http.Removed);
    Assert.Equal(2, http.Requests.Count(r => r.Url.AbsolutePath == "/v1/devices/remove"));
    Assert.False(File.Exists(path)); Assert.Equal("cloud sign-out: remove this PC ok", log[^1]);
  }

  [Fact] public async Task WithoutTheServiceThePcStillSignsOutLocally()
  {
    var (account, http, log, path) = Make();
    await CloudJoinTests.SignInAsync(account);
    http.RemoveFails = true;
    await account.SignOutAsync();
    Assert.Equal(CloudPhase.SignedOut, account.Snapshot.Phase); Assert.False(File.Exists(path));
    Assert.Empty(http.Removed);
    Assert.Equal("cloud sign-out: remove this PC failed: service unavailable", log[^1]);
    Assert.EndsWith("/logout", http.Requests[^1].Url.AbsolutePath, StringComparison.Ordinal);
  }

  [Fact] public async Task SigningOutWhenNotSignedInSendsNothing()
  {
    var (account, http, _, _) = Make();
    await account.SignOutAsync();
    Assert.Empty(http.Requests);
    Assert.Equal(CloudPhase.SignedOut, account.Snapshot.Phase);
  }
}
