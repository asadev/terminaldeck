using System.Text;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.Core.Tests.Browser;
public sealed class BrowserPrivacyTests
{
  private sealed class State<T> : IStateStore<T> { public T? Value; public T? Load() => Value; public void Save(T value) => Value = value; }
  private sealed class Secrets : ISecretStore
  { public Dictionary<string, byte[]> Rows = []; public ValueTask<byte[]?> ReadAsync(string key, CancellationToken ct) => ValueTask.FromResult(Rows.GetValueOrDefault(key)?.ToArray()); public ValueTask WriteAsync(string key, ReadOnlyMemory<byte> value, CancellationToken ct) { Rows[key] = value.ToArray(); return ValueTask.CompletedTask; } public ValueTask DeleteAsync(string key, CancellationToken ct) { Rows.Remove(key); return ValueTask.CompletedTask; } }
  [Fact] public async Task PasswordMetadataIsPublicButUseRequiresExactProfileAndOrigin()
  {
    var state = new State<BrowserLogins>(); var secret = new Secrets(); var service = new BrowserPrivacy(new State<BrowserPrivacyPreferences>(), state, secret, "own/");
    var row = await service.SaveLoginAsync("default", "https://example.test/login", "ada", "own-test-secret");
    Assert.DoesNotContain("own-test-secret", System.Text.Json.JsonSerializer.Serialize(state.Value));
    Assert.Equal("own-test-secret", await service.PasswordForUseAsync(row.Id, "default", "https://example.test/settings"));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.PasswordForUseAsync(row.Id, "default", "https://other.test/"));
    await service.ForgetAsync("default", row.Id); Assert.Empty(secret.Rows); Assert.Empty(service.Logins("default"));
  }
  [Fact] public void ImportedCookiesRejectUnsafeDomainsAndUnsecuredSameSiteNone()
  { Assert.Single(BrowserPrivacy.Cookies("""[{"name":"session","value":"synthetic","domain":"example.test"}]""")); Assert.Throws<ArgumentException>(() => BrowserPrivacy.Cookies("""[{"name":"session","value":"synthetic","domain":"bad/host"}]""")); Assert.Throws<ArgumentException>(() => BrowserPrivacy.Cookies("""[{"name":"session","value":"synthetic","domain":"example.test","secure":false,"sameSite":"None"}]""")); }
  [Fact] public async Task PasswordByteLimitAndMalformedCookieFieldsFailBeforeAnyProtectedWrite()
  {
    var secrets = new Secrets(); var service = new BrowserPrivacy(new State<BrowserPrivacyPreferences>(), new State<BrowserLogins>(), secrets, "own/");
    await Assert.ThrowsAsync<ArgumentException>(async () => await service.SaveLoginAsync("default", "https://example.test", "ada", new string('é', 1281)));
    Assert.Empty(secrets.Rows);
    Assert.Throws<ArgumentException>(() => BrowserPrivacy.Cookies("[{\"name\":null,\"value\":\"synthetic\",\"domain\":\"example.test\"}]"));
    Assert.Throws<ArgumentException>(() => BrowserPrivacy.Cookies("[null]"));
    Assert.Throws<ArgumentException>(() => BrowserPrivacy.Cookies(System.Text.Json.JsonSerializer.Serialize(new[] { new { name = "x", value = "synthetic", domain = "example.test", path = "/" + new string('a', 2048) } })));
  }

  [Fact] public void PageMessagesCannotForgeTrustedSubmitProofOrCrossPrivateAutomationAndOriginBoundaries()
  {
    System.Text.Json.JsonElement Capture(string proof, string origin = "https://example.test") => System.Text.Json.JsonSerializer.SerializeToElement(new { kind = "deck-save-login", proof, origin, username = "ada", password = "only-a-test" });
    Assert.False(BrowserPrivacy.ValidCapture(Capture("forged"), "private-nonce", "https://example.test/login", false, false));
    Assert.False(BrowserPrivacy.ValidCapture(Capture("private-nonce"), "private-nonce", "https://example.test/login", true, false));
    Assert.False(BrowserPrivacy.ValidCapture(Capture("private-nonce"), "private-nonce", "https://example.test/login", false, true));
    Assert.False(BrowserPrivacy.ValidCapture(Capture("private-nonce", "https://other.test"), "private-nonce", "https://example.test/login", false, false));
    Assert.True(BrowserPrivacy.ValidCapture(Capture("private-nonce"), "private-nonce", "https://example.test/login", false, false));
  }

}
