using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Mcp;

namespace TerminalDeck.Core.Tests.Cloud;

// Server sign-ins as a saved-passwords source (the Mac's CloudSecretsServerPortTests / CloudSecretsAdapterTests server
// cases): a Mac's record (its server's UUID id, the server inside) lands under the same server with no question and
// goes back byte for byte; a different password here is kept; a key sign-in has no place here; the delete rule's remove
// forgets only an unchanged password.
public sealed class CloudSecretsServerPortTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-secrets-servers-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(folder, true); } catch (Exception) { } }
  private (CloudSecretsServerStore Store, ServerStore Servers, TestSecretStore Secrets) Make()
  {
    var secrets = new TestSecretStore();
    var servers = new ServerStore(AppDataRoot.Explicit(Path.Combine(folder, "data")), secrets);
    return (new CloudSecretsServerStore(servers, Path.Combine(folder, "server-ids.json")), servers, secrets);
  }
  private const string MacId = "5f0e6a2c-9b1d-4c3e-8f7a-1b2c3d4e5f60";
  private static CloudSecretRecord FromMac(string password, string extra = "") => new("servers", MacId, CloudSecretsDomains.Server, CloudJson.Parse(
    "{\"kind\":\"password\",\"password\":\"" + password + "\",\"server\":{\"address\":\"build.example.net\",\"lookOnly\":true,\"name\":\"Build box\",\"port\":22,\"username\":\"deploy\"}" + extra + "}"));

  [Fact]
  public async Task A_Macs_server_sign_in_lands_under_the_same_server_and_goes_back_byte_for_byte()
  {
    var (store, servers, _) = Make();
    var incoming = FromMac("fixture-pass-1");
    await store.ValidateAsync(incoming);
    Assert.Equal(CloudApplyStatus.Applied, await store.MergeAsync(incoming));
    Assert.True(await store.VerifyAsync(incoming, CloudApplyStatus.Applied));
    var row = Assert.Single(servers.List());
    Assert.Equal(MacId.Replace("-", ""), row.Id);
    Assert.True(row.Access.LookOnly);
    var back = Assert.Single(await store.CaptureAsync());
    Assert.Equal(MacId, back.RecordId);
    Assert.Equal(incoming.Canonical(), back.Canonical());
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await store.MergeAsync(incoming));
  }

  [Fact]
  public async Task A_different_password_here_is_kept_and_a_key_sign_in_or_an_unknown_member_is_refused()
  {
    var (store, _, _) = Make();
    await store.MergeAsync(FromMac("his-own"));
    Assert.Equal(CloudApplyStatus.KeptBoth, await store.MergeAsync(FromMac("other")));
    Assert.True(await store.VerifyAsync(FromMac("other"), CloudApplyStatus.KeptBoth));
    await Assert.ThrowsAsync<CloudFailure>(() => store.ValidateAsync(FromMac("x", ",\"note\":\"y\"")));
    var key = new CloudSecretRecord("servers", MacId, CloudSecretsDomains.Server, CloudJson.Parse("""{"kind":"key","privateKey":"-----BEGIN-----"}"""));
    await Assert.ThrowsAsync<CloudFailure>(() => store.MergeAsync(key));
  }

  [Fact]
  public async Task A_sign_in_with_no_server_waits_and_remove_forgets_only_an_unchanged_password()
  {
    var (store, servers, secrets) = Make();
    var bare = new CloudSecretRecord("servers", MacId, CloudSecretsDomains.Server, CloudJson.Parse("""{"kind":"password","password":"p"}"""));
    Assert.Equal("unavailable", (await Assert.ThrowsAsync<CloudFailure>(() => store.MergeAsync(bare))).Code);
    await store.MergeAsync(FromMac("p1"));
    Assert.False(await store.RemoveAsync(FromMac("p2")));
    Assert.True(await store.RemoveAsync(FromMac("p1")));
    Assert.Empty(secrets.Values);
    Assert.Single(servers.List());
    Assert.Equal("Build box", CloudSecretsServerStore.Name(FromMac("p1")));
  }
}
