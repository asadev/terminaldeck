using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class CredentialTests
{
  private static AppDataRoot Root() => AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w3", Guid.NewGuid().ToString("N")));
  [Fact]
  public async Task CredentialsRoundTripAcrossStoreInstancesAndDelete()
  {
    var root = Root(); var store = new WindowsCredentialStore(root);
    var name = $"{Brand.Name}/{root.NamespaceId}/tests/roundtrip";
    try
    {
      await store.WriteAsync(name, Encoding.UTF8.GetBytes("synthetic-test-value"));
      Assert.Equal("synthetic-test-value", Encoding.UTF8.GetString((await new WindowsCredentialStore(root).ReadAsync(name))!));
      await store.DeleteAsync(name); Assert.Null(await store.ReadAsync(name));
    }
    finally { await store.DeleteAsync(name); }
  }
  [Fact]
  public async Task CredentialsRejectAnotherDataRoot()
  {
    var one = Root(); var two = Root();
    await Assert.ThrowsAsync<ArgumentException>(async () => await new WindowsCredentialStore(two).ReadAsync($"{Brand.Name}/{one.NamespaceId}/tests/value"));
  }
  [Fact]
  public async Task CoreAccountCredentialInterfaceUsesRealWindowsStore()
  {
    var root = Root(); var accounts = new AccountCredentials(new WindowsCredentialStore(root), root);
    var reference = await accounts.StoreAsync(Encoding.UTF8.GetBytes("synthetic-account"));
    try { Assert.Equal("synthetic-account", Encoding.UTF8.GetString((await accounts.ReadAsync(reference))!)); }
    finally { await accounts.DeleteAsync(reference); }
  }
  [Fact]
  public void DpapiRoundTripRejectsOtherRootAndTampering()
  {
    var root = Root(); var one = new CurrentUserDpapi(root); var plain = Encoding.UTF8.GetBytes("synthetic-vault");
    var encrypted = one.Protect(plain);
    Assert.False(encrypted.AsSpan().SequenceEqual(plain));
    Assert.Equal(plain, new CurrentUserDpapi(root).Unprotect(encrypted));
    Assert.Throws<CryptographicException>(() => new CurrentUserDpapi(Root()).Unprotect(encrypted));
    encrypted[^1] ^= 1;
    Assert.Throws<CryptographicException>(() => one.Unprotect(encrypted));
  }
}
